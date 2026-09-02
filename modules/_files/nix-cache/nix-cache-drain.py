#!/usr/bin/env python3
"""Drain the R2 push spool that the post-build-hook fills.

WHY THIS EXISTS. Nix runs a post-build-hook SYNCHRONOUSLY, blocking its build
loop, and the hook used to run the whole `nix copy` to R2 inline. Measured on
2026-09-02: 322 hook invocations totalling 8182 s (136 min) in one day, with a
601 s `timeout` kill on a devenv-profile whose closure is 4.12 GB across 202
paths. A killed push registers NOTHING, so the next `direnv reload` paid the
same 601 s again — a cost that never amortised. The hook is now an enqueuer that
returns in ~1 ms; this script does the work out of band.

The economics that make the split work: `nix copy` queries the destination first
and skips what it already has, so an interrupted drain loses only the NAR in
flight. Everything already uploaded stays uploaded and is never paid for twice.

STATE LIVES IN THE FILESYSTEM, per the "Any script that processes a list must be
resumable" rule in AGENTS.md. One empty file per queued store path:

    $NIX_CACHE_SPOOL/queue/<hash>-<name>      waiting        (mtime = enqueued)
    $NIX_CACHE_SPOOL/retry/<n>/<hash>-<name>  failed n times (mtime = last try)

The file NAME is the entire payload and `open(O_CREAT)` is atomic, so there is
no half-written record to recover from and no progress file to go missing
exactly when a run dies badly — which is the case a progress file exists for.

Five outcomes are counted separately and never collapsed:
  SUCCESS  pushed to R2
  SKIP     garbage-collected before the drain, or over the closure limit —
           logged per path with its reason, so a later cache miss on the other
           Mac has something to be traced back to
  ERROR    the push failed; the entry moves to the next retry level
  GIVEUP   the entry failed at every level and is dropped for good. Counted
           separately from ERROR on purpose: an earlier version reported
           "0 errors" on the run that permanently dropped a path
  CLEANUP  a retry entry whose backoff expired and was requeued, or a malformed
           spool entry swept

Each run pushes at most two groups: everything at level 0 in one `nix copy`, and
ONE entry that has already failed, alone. See main() for why that split is not
an optimisation but the fix for a starvation bug.

Exit codes:  0 did work OR nothing to do (the summary distinguishes them)
             1 a group failed; its entries stay queued and will be retried
             2 misconfiguration — a required environment variable is missing,
               or this was run without the privileges the spool needs

python3, stdlib only, deliberately WITHOUT the PEP-723/uv header AGENTS.md
prescribes for skill scripts: there are no dependencies to lock, and `uv run
--frozen` inside a root LaunchDaemon would additionally need a writable
UV_CACHE_DIR. Precedent for a Nix-built stdlib-python script in this repo:
modules/boundary.nix.
"""

import fcntl
import json
import os
import re
import signal
import subprocess
import sys
import time

# Retry backoff by level: a level-1 entry is retried after 5 min, a level-5 one
# after 24 h, and level 6 is given up on. Bounded on purpose — an entry that
# fails six times over more than a day is not going to start working, and the
# alternative is a spool that grows without limit and hides the healthy entries.
BACKOFF = [300, 900, 3600, 14400, 86400]
MAX_LEVEL = len(BACKOFF)

# One `nix copy` per drain, so the closures deduplicate against each other. The
# cap is about argv size and about how much work one run may hold the lock for,
# not about correctness; whatever it leaves behind is drained 300 s later.
MAX_BATCH = 400

# The push may legitimately take many minutes on a ~3-4 MB/s uplink. This bound
# exists only so a wedged transfer cannot hold the lock forever.
PUSH_TIMEOUT = 3600

# Store path basename: 32 nix-base32 characters, a dash, then the name. Anything
# else in the spool did not come from the hook and is swept as CLEANUP rather
# than handed to nix — one malformed argument makes `nix-store` exit 1 and would
# take the whole batch down with it.
NAME_RE = re.compile(r"^[0-9a-df-np-sv-z]{32}-.+$")

# The push runs in its own session so this process can killpg it on timeout. The
# flip side is that it is then OUTSIDE launchd's job process group, so launchd
# stopping the job would leave the `nix copy` running — and with RunAtLoad the
# reloaded job would immediately start a second one for the same paths, both
# holding the uplink, neither holding the flock. A `just switch` reloads the
# daemon, so this is an ordinary Tuesday, not a corner case. Hence: remember the
# child and take it with us.
CHILD = None


def _terminate(signum, _frame):
    child = CHILD
    if child is not None:
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(child.pid, sig)
            except (ProcessLookupError, PermissionError):
                break
            try:
                child.wait(timeout=10)
                break
            except subprocess.TimeoutExpired:
                continue
    record(status="ABORT", exit=128 + signum, reason=signal.Signals(signum).name)
    # 128+signum, the shell convention, so the exit code says which signal.
    os._exit(128 + signum)


def die(code, message):
    print(message, file=sys.stderr)
    sys.exit(code)


def env(name):
    """Required environment variable, or exit 2 naming it.

    Never `.get(name, default)`. A launchd job inherits no shell environment
    (AGENTS.md), so a missing value here means the Nix wrapper stopped baking it
    in — and a default would turn that into a drain writing to the wrong spool,
    reporting success all the while.
    """
    try:
        return os.environ[name]
    except KeyError:
        die(2, f"nix-cache-drain: required environment variable {name} is not set. "
               "Run this through the Nix-generated `nix-cache-drain` wrapper, which "
               "bakes every value in at build time.")


SPOOL = env("NIX_CACHE_SPOOL")
LOG = env("NIX_CACHE_LOG")
PUSH = env("NIX_CACHE_PUSH")
LOCK = env("NIX_CACHE_DRAIN_LOCK")
SECRETS_DIR = env("NIX_CACHE_SECRETS_DIR")
MAX_CLOSURE = int(env("NIX_CACHE_MAX_CLOSURE_BYTES"))

QUEUE = os.path.join(SPOOL, "queue")
RETRY = os.path.join(SPOOL, "retry")


def record(**fields):
    """Append ONE structured line to the shared push log.

    One record = one printf, exactly as the hook does it: a single write() under
    O_APPEND is atomic, while several are free to interleave. Records stay short
    so the guarantee holds. An unwritable log must never fail a drain, hence the
    bare except.
    """
    line = "{ts} pid={pid} {rest}\n".format(
        ts=time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        pid=os.getpid(),
        rest=" ".join(f"{k}={v}" for k, v in fields.items()),
    )
    try:
        fd = os.open(LOG, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            os.write(fd, line.encode("utf-8", "replace"))
        finally:
            os.close(fd)
    except OSError:
        pass


def fold(text, limit=240):
    """Collapse a command's output to one log-sized line, keeping the TAIL.

    The diagnosis is at the end of nix's output, and the record has to stay
    inside the atomic-write bound.
    """
    return " ".join(text.split())[-limit:]


def scan():
    """Everything currently spooled, as {name: level} (0 = queue, n = retry/n).

    Malformed names are removed here and counted as CLEANUP; a duplicate that
    exists both in the queue and under retry keeps the queue copy, because the
    hook only ever writes into the queue and a fresh enqueue means the path was
    built again.
    """
    entries, cleaned = {}, 0
    for level in range(MAX_LEVEL, 0, -1):
        d = os.path.join(RETRY, str(level))
        for name in os.listdir(d) if os.path.isdir(d) else []:
            if NAME_RE.match(name):
                if name in entries:          # same path at two levels: keep the
                    unlink(slot(name, entries[name]))   # newer (lower) one only
                entries[name] = level
            else:
                unlink(os.path.join(d, name))
                cleaned += 1
    for name in os.listdir(QUEUE) if os.path.isdir(QUEUE) else []:
        if NAME_RE.match(name):
            # A path re-enqueued by the hook drops back to level 0 — and its
            # stale retry copy is redundant, since store paths are immutable and
            # the two entries name the same content.
            if name in entries:
                unlink(os.path.join(RETRY, str(entries[name]), name))
            entries[name] = 0
        else:
            unlink(os.path.join(QUEUE, name))
            cleaned += 1
    return entries, cleaned


def unlink(path):
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass


def slot(name, level):
    return os.path.join(QUEUE if level == 0 else os.path.join(RETRY, str(level)), name)


def due(name, level):
    """Has this retry entry's backoff expired? Level 0 is always due."""
    if level == 0:
        return True
    try:
        return os.stat(slot(name, level)).st_mtime + BACKOFF[level - 1] <= time.time()
    except FileNotFoundError:
        return False


def demote(name, level):
    """Move a failed entry to the next retry level, or give up on it."""
    if level + 1 > MAX_LEVEL:
        unlink(slot(name, level))
        record(status="GIVEUP", exit=0, path=name, attempts=level + 1)
        return False
    dest_dir = os.path.join(RETRY, str(level + 1))
    os.makedirs(dest_dir, exist_ok=True)
    dest = os.path.join(dest_dir, name)
    os.replace(slot(name, level), dest)
    os.utime(dest, None)  # restart the backoff clock from this attempt
    return True


def run(argv, timeout=None):
    """Run a command in its OWN SESSION; return (rc, stdout, stderr).

    ESCALATION is the point, not the group. An earlier version of this comment
    claimed GNU `timeout` had signalled only one pid; that is wrong — `timeout`
    calls setpgid(2) and signals the whole group unless --foreground is given.
    What actually happened is that `nix copy` was measured still running minutes
    after its FAIL record was written, i.e. it took the SIGTERM and did not die
    promptly, and a second upload then competed with it for the same uplink.
    Hence SIGTERM, then SIGKILL if it is still there 30 s later. The new session
    is what makes killpg addressable from here without signalling ourselves.

    stdout and stderr stay SEPARATE, which is not tidiness: `nix path-info
    --json` writes its progress and its "Using saved setting …" notices to
    stderr, and merging them into stdout fed `json.loads` a line of prose.
    Caught in testing, where the merged form crashed on the first real call.
    """
    global CHILD
    proc = subprocess.Popen(
        argv,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    CHILD = proc
    try:
        out, err = proc.communicate(timeout=timeout)
        return proc.returncode, out, err
    except subprocess.TimeoutExpired:
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(proc.pid, sig)
            except ProcessLookupError:
                # Already gone; still reap it so no zombie is left, and do not
                # report "would not die" for a process that did.
                out, err = proc.communicate()
                return 124, out, err + f"\n[timed out after {timeout}s, had already exited]"
            try:
                out, err = proc.communicate(timeout=30)
                return 124, out, err + f"\n[timed out after {timeout}s, group killed with {sig.name}]"
            except subprocess.TimeoutExpired:
                continue
        return 124, "", f"[timed out after {timeout}s, group would not die]"
    finally:
        CHILD = None


def invalid_paths(paths):
    """Store paths that no longer exist locally, in ONE call.

    Both halves matter. It is the SKIP predicate — a path the local GC threw
    away in the meantime is ephemeral, and the cache exists to save rebuilds,
    not to preserve rubbish. And it is a precondition: a single invalid argument
    makes `nix copy` fail outright, which would push a whole healthy batch into
    the retry levels.
    """
    rc, out, err = run(["nix-store", "--check-validity", "--print-invalid"] + paths)
    if rc != 0:
        # Do not guess. Reporting "nothing invalid" here would hand the bad
        # argument straight to nix copy and fail the batch anyway, with a
        # message pointing at the wrong step.
        raise RuntimeError(
            f"nix-store --check-validity failed (exit {rc}): {fold(out + err)}")
    return {line.strip() for line in out.splitlines() if line.strip()}


def oversized(paths):
    """Paths whose CLOSURE exceeds the limit, as {path: bytes}.

    A binary cache has to be referentially complete, so `nix copy` expands every
    argument to its closure (see the note at the bottom of nix-cache-push). The
    closure, not the path, is therefore what an upload actually costs, and it is
    what the limit is measured against.
    """
    if MAX_CLOSURE <= 0:
        return {}
    rc, out, err = run(["nix", "path-info", "--json", "-S"] + paths)
    if rc != 0:
        # Not fatal: a missing size check only means nothing is filtered. Say so
        # rather than silently behaving as if every closure fit.
        print("nix-cache-drain: closure sizes unavailable, limit not applied: "
              + fold(out + err), file=sys.stderr)
        return {}
    data = json.loads(out)
    items = data.items() if isinstance(data, dict) else ((e["path"], e) for e in data)
    return {p: m["closureSize"] for p, m in items
            if (m or {}).get("closureSize", 0) > MAX_CLOSURE}


def push_group(names, levels):
    """Push one group of spool entries. Returns (ok, gone, big, retried, gaveup, rc, out).

    A group is pushed with ONE `nix copy` so its closures deduplicate against
    each other. Callers pass groups that may safely share a fate: everything at
    level 0 has never failed, while anything that has failed is pushed alone.
    """
    paths = {f"/nix/store/{n}": n for n in names}
    ok = gone_n = big_n = retried = gaveup = 0

    try:
        gone = invalid_paths(list(paths))
    except RuntimeError as e:
        return 0, 0, 0, 0, 0, 1, str(e)

    for pth in gone:
        n = paths[pth]
        # Logged per path, exactly like the closure-limit skip. The docstring
        # separates these two reasons, so the log must too — otherwise a later
        # cache miss on the other Mac has no trace to be chased with.
        record(status="SKIP", exit=0, reason="garbage-collected", path=n)
        unlink(slot(n, levels[n]))
        gone_n += 1

    live = [pth for pth in paths if pth not in gone]

    for pth, size in (oversized(live) if live else {}).items():
        # Never a silent cap (AGENTS.md): what was dropped, and how big it was,
        # goes in the log where the next cache miss can be traced back to it.
        record(status="SKIP", exit=0, reason="closure-limit", bytes=size,
               path=paths[pth])
        unlink(slot(paths[pth], levels[paths[pth]]))
        big_n += 1
        live.remove(pth)

    rc, out, err = ((0, "", "") if not live
                    else run([PUSH] + sorted(live), timeout=PUSH_TIMEOUT))
    out = out + err

    if rc == 0:
        for pth in live:
            unlink(slot(paths[pth], levels[paths[pth]]))
        ok = len(live)
    else:
        for pth in live:
            n = paths[pth]
            if demote(n, levels[n]):
                retried += 1
            else:
                # demote() already logged GIVEUP and removed the entry. Counting
                # it is not bookkeeping pedantry: without this the summary says
                # "0 errors" while a path is dropped from the cache forever.
                gaveup += 1
    return ok, gone_n, big_n, retried, gaveup, rc, out


def main():
    signal.signal(signal.SIGTERM, _terminate)
    signal.signal(signal.SIGINT, _terminate)

    for d in (QUEUE, RETRY):
        try:
            os.makedirs(d, exist_ok=True)
        except OSError as e:
            die(2, f"nix-cache-drain: cannot create spool directory {d}: {e}")

    # Non-blocking: a drain still running from the previous StartInterval keeps
    # the lock, and the right answer is to come back in 300 s, not to queue up a
    # second uploader competing for the same uplink.
    #
    # The spool and the lock are root-owned, so an unprivileged run belongs here
    # and must say so. It used to die with a raw PermissionError traceback and
    # exit 1, which collides with the documented meaning of 1 ("batch failed").
    try:
        lock_fd = os.open(LOCK, os.O_WRONLY | os.O_CREAT, 0o644)
    except PermissionError:
        die(2, f"nix-cache-drain: cannot open {LOCK} — this runs as root, from the "
               "nix-cache-drain LaunchDaemon. To drain by hand:\n"
               "  sudo /run/current-system/sw/bin/nix-cache-drain")
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("another drain is running — nothing done")
        record(status="busy", exit=0)
        return 0

    # The R2 credentials live in the user's sops-nix directory, which is
    # populated by home-manager activation, i.e. only after login. Before that a
    # push cannot work, and burning retry levels on it would give up on entries
    # for a reason that has nothing to do with them.
    #
    # All THREE files, not just the access key: nix-cache-push needs the id, the
    # secret and the signing key, and checking one of them would let a half-
    # populated secrets directory consume the whole retry ladder.
    missing = [f for f in ("r2_access_key_id", "r2_secret_access_key",
                           "nix_cache_signing_key")
               if not os.access(os.path.join(SECRETS_DIR, f), os.R_OK)]
    if missing:
        entries, _ = scan()
        print(f"secrets not readable yet ({', '.join(missing)}) — "
              f"{len(entries)} entries left queued")
        record(status="DEFER", exit=0, reason="secrets", missing=",".join(missing),
               queued=len(entries))
        return 0

    started = time.time()
    entries, cleaned = scan()

    ready = {n: l for n, l in entries.items() if due(n, l)}
    waiting = len(entries) - len(ready)

    # TWO groups per run, and the split is what keeps either from starving the
    # other. The first version escalated the WHOLE run to a single path as soon
    # as any entry reached level 2, which meant one transient R2 outage collapsed
    # the drainer to one path per 300 s — and every freshly built path then
    # waited behind a backoff ladder that runs to 24 h. Measured against the
    # ladder in BACKOFF, that is up to ~33 h of no new paths reaching the cache.
    #
    #   fresh   everything at level 0. Never failed, so it may share one push.
    #   retry   exactly ONE due entry that HAS failed, pushed alone, highest
    #           level first. That is the isolation the escalation was for, and
    #           it costs one extra `nix copy` rather than the whole queue.
    fresh = sorted(n for n, l in ready.items() if l == 0)[:MAX_BATCH]
    failed = sorted((l, n) for n, l in ready.items() if l >= 1)
    retry_one = [failed[-1][1]] if failed else []
    deferred = len(ready) - len(fresh) - len(retry_one)

    if not fresh and not retry_one:
        print(f"nothing to do — {len(entries)} queued, {waiting} waiting on backoff, "
              f"{cleaned} cleaned up")
        if cleaned:
            record(status="drain", exit=0, batch=0, ok=0, skip=0, retry=0, giveup=0,
                   cleanup=cleaned, dur="0s", first="-")
        return 0

    ok = gone_n = big_n = retried = gaveup = 0
    worst_rc, messages = 0, []
    for group in (fresh, retry_one):
        if not group:
            continue
        g_ok, g_gone, g_big, g_retry, g_give, rc, out = push_group(group, ready)
        ok += g_ok; gone_n += g_gone; big_n += g_big
        retried += g_retry; gaveup += g_give
        if rc != 0:
            worst_rc = rc
        if out:
            messages.append(out)

    for message in messages:
        print(message, end="" if message.endswith("\n") else "\n")

    dur = int(time.time() - started)
    skip = gone_n + big_n
    batch = len(fresh) + len(retry_one)
    fields = dict(status="drain" if worst_rc == 0 else "FAIL", exit=worst_rc,
                  batch=batch, ok=ok, skip=skip, retry=retried, giveup=gaveup,
                  cleanup=cleaned, dur=f"{dur}s",
                  first=(fresh or retry_one)[0])
    if worst_rc != 0:
        fields["err"] = f'"{fold(" ".join(messages))}"'
    record(**fields)

    print(f"{ok} pushed, {skip} skipped ({gone_n} garbage-collected, "
          f"{big_n} over closure limit), {retried} errors, {gaveup} given up, "
          f"{cleaned} cleaned up — {deferred + waiting} still queued")
    return 0 if worst_rc == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
