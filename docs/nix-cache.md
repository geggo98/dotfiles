# The R2 Nix binary cache: async push, and what it mirrors

Moved out of `AGENTS.md` to stay under Codex's 32 KiB project-doc budget. AGENTS.md keeps a short pointer; this file has the full, unedited text.

### Key Architectural Decisions — the "Binary cache (R2)" bullet

- **Binary cache (R2):** both hosts share a Cloudflare R2 cache (`modules/nix-cache.nix`). Pull is a public custom-domain substituter; push is a signed `nix copy` run by the **`nix-cache-drain` LaunchDaemon**, not by the build itself — the root `post-build-hook` only drops a file into `/var/spool/nix-cache-push/queue` (`just cache-seed`/`cache-push` still push synchronously, on purpose). The hook is referenced by the **stable** `/run/current-system/sw/bin` path, but Determinate's `nix-daemon` reads the hook setting only at startup and `darwin-rebuild switch` does **not** restart it — after first enabling the cache, run `just daemon-restart` (or reboot) once. Push credentials: `r2_secret_access_key` stores a Cloudflare API token (`cfat_…`) whose SHA-256 the push script derives as the S3 secret

### The push is asynchronous, and why

Nix runs a `post-build-hook` **synchronously, blocking its own build loop**. For a long
time this repo's hook did the whole `nix copy` to R2 inline behind a `timeout 600`, so
every locally built path cost up to ten minutes of wall clock before the build that
produced it was considered finished. What that actually cost, from
`/var/log/nix-cache-push.log`:

| day | hook invocations | total hook time | worst single record |
|---|---|---|---|
| 2026-08-25 | 67 | 9040 s | 11 killed at `exit=124` |
| 2026-09-02 | 322 | 8182 s (136 min) | `dur=601s` |

(The 2026-09-02 row is a mid-afternoon snapshot — the log was read while the problem was
still happening — not a full day. Across the whole log there are 13 `exit=124` records,
10 of which name a devenv output.)

**A killed push registers nothing**, and that is the part that made it unbounded: the
`nix copy` had transferred hundreds of megabytes, the `timeout` shot it, nothing was
recorded at the destination, and the next build of the same path paid the same 601 s
again. It never amortised.

The worst case was a devenv shell — a per-project profile rebuilt on every `direnv
reload`, whose closure is **4.12 GB across 202 paths**, because a binary cache has to be
referentially complete and `nix copy` therefore expands every argument to its closure.

**The symptom pointed at the wrong thing.** The progress display showed
`Downloading … from cache.nixos.org — 11m24s` and read as a slow network. Measured the
same minute: that exact NAR is 29 MB and `curl`s in **0.69 s**; the machine had 67 MB/s
down and 40 MB/s up, and all four substituters answered `nix-cache-info` in under 0.2 s.
Nix simply keeps displaying the last open activity while the daemon blocks in the hook.
**Do not diagnose a stalled Nix from its progress line** — check
`/var/log/nix-cache-push.log` and `ps` for a `nix copy` first.

So the hook now only **enqueues**: one empty file per output path in
`/var/spool/nix-cache-push/queue`, named after the store path, and it returns in ~20 ms
(measured; the same hook previously took 2–601 s per invocation, median a few seconds).
`launchd.daemons.nix-cache-drain` runs
`nix-cache-drain` every 300 s and hands **all** waiting paths to `nix-cache-push` in one
call, so their closures deduplicate against each other instead of being re-queried per
build.

Four properties are load-bearing, and each replaces something that was broken:

- **State is the file name, nothing else** (mtime = when it was queued or last tried).
  `open(O_CREAT)` is atomic, so there is no half-written entry, and no progress file to
  be missing exactly when a run died badly — which is the case a progress file exists
  for. Resume is "what is still in the directory".
- **An interrupted drain now costs only the NAR in flight.** `nix copy` asks the
  destination what it already has, so everything uploaded before the interruption stays
  uploaded. This is the whole reason the split fixes the problem rather than moving it.
- **The timeout ESCALATES to SIGKILL.** A `nix copy` was measured still running minutes
  after its `FAIL` record was written, with a second one alongside it competing for the
  same uplink. The tempting explanation — that `timeout` had signalled only one pid — is
  **wrong**: GNU `timeout` calls `setpgid(2)` and signals the whole group unless
  `--foreground` is given. What actually happened is that `nix copy` took the SIGTERM and
  did not die promptly. So the drainer sends SIGTERM, waits 30 s, then SIGKILL; the new
  session exists so `killpg` is addressable from the drainer without signalling itself.
  It also installs a SIGTERM handler of its own, because the push runs *outside* launchd's
  job process group: without one, a `just switch` that reloads the daemon mid-drain would
  orphan the running `nix copy` and `RunAtLoad` would immediately start a second one for
  the same paths.
- **Failures back off and are eventually given up on** — `retry/1..5` at 5 min, 15 min,
  1 h, 4 h, 24 h, then `status=GIVEUP` (counted separately from errors: an earlier version
  reported "0 errors" on the very run that dropped a path for good).

  Each run pushes **two groups**: everything at level 0 in one `nix copy`, and exactly
  **one** already-failed entry, alone. That split is a bug fix, not an optimisation. The
  first version escalated the *whole run* to a single path as soon as any entry reached
  level 2 — so one transient R2 outage collapsed the drainer to one path per 300 s, and
  freshly built paths then queued behind a ladder that runs to 24 h: up to ~33 h in which
  nothing new reached the cache. Isolating the poison entry costs one extra `nix copy`,
  not the whole queue.

Two filters, both of which log what they drop (**never a silent cap**):

- **Per-project devenv outputs are not pushed at all** — everything whose name starts
  `devenv-`, except the devenv package itself (`devenv`, `devenv-<version>`,
  `devenv-wrapped-<version>`). They are rebuilt on every `direnv reload`, are specific to
  one machine and one checkout, and the other Mac can never reuse them.

  **This started as an exact list of four names and that was a disclosure bug, not a
  tuning miss.** The four were chosen because they appeared in the timeout records —
  wrong criterion, because the leaky outputs are *small* and therefore never timed out. A
  `devenv-files` output is a script containing the checkout's **absolute path**, and
  `devenv-processes-<name>` takes `<name>` verbatim from the project's own `processes.*`
  keys, which then becomes the `StorePath:` line of a world-readable narinfo in a bucket
  that is public by design. Measured in one store: `devenv-files` 58, `-files-cleanup`
  60, `-git-hooks-install` 11, `-git-hooks-run` 10, `-enterShell` 6, `-container-copy` 6,
  `-python-uv` 4, `-test` 3, `-processes-*` 3, `-flake-*` 4 — every one of them outside a
  four-name list. **When a filter exists to keep a category out of a public place, derive
  it from the category, never from the incidents that made you notice.**

  The filter lives in the **hook**, because `nix-cache-push` is also the interactive path
  (`just cache-push …-devenv-profile` must still do what it was told) and because a
  filter in the drainer would let the spool accumulate entries every run discards. The
  keep-arm is listed first because zsh takes the first matching `case` arm and
  `devenv-wrapped-2.2.2` matches both. `rust_devenv-*` and `+mcp-devenv*` do not start
  with `devenv-` once the hash is stripped, so they are unaffected.
- **Closures over 64 GiB are skipped**, logged with their size
  (`status=SKIP reason=closure-limit bytes=…`). That bound is a backstop against one
  pathological output, deliberately **not** a cost policy, and the first attempt got this
  wrong in a way worth recording: a 3 GiB cap looked reasonable and skipped
  `darwin-system` (closure 24.35 GB), `home-manager-generation` (21.63 GB) and
  `activation-<user>` (21.63 GB) — precisely the closures this shared cache exists to
  hand to the other Mac. Their real push cost, from the log, is **2–4 seconds**, because
  `nix copy` asks the destination first and uploads only what R2 lacks. **Closure size
  overestimates upload cost by three orders of magnitude here**, so do not tighten this
  number in the belief that it measures money. What bounds the genuinely expensive case
  is the drainer's 3600 s timeout, the retry backoff and `status=GIVEUP` — those measure
  the work instead of guessing at it. `NIX_CACHE_MAX_CLOSURE_BYTES=0` disables it.

Operationally:

```bash
just cache-queue      # depth per retry level + the oldest entry (no sudo)
just cache-log        # one line per enqueue and per drain that did something
sudo /run/current-system/sw/bin/nix-cache-drain   # drain now (`just cache-drain` prints it)
```

**Taking something back out: `just cache-prune`.** The push side only ever adds, and a
filter cannot retract what it already published — which mattered on 02.09.2026, when the
devenv filter turned out to be too narrow (above). `modules/_files/nix-cache/nix-cache-prune.py`
removes a whole *category* of store paths, dry-run by default:

```bash
just cache-prune devenv          # what would go, and why
just cache-prune devenv apply    # the one-way door — R2 has no versioning here
```

Three properties are load-bearing and each cost a measurement. It deletes the transitive
**upward** closure, because a binary cache must be closed under references — on the devenv
set that pulled in 53 further objects (`tasks.json`, `nix-darwin-env`,
`process-compose.yaml`), all of them devenv outputs without the prefix, and deleting the
seed alone would have left 300 dangling references. It keeps any **NAR a survivor still
points at**, since identical store paths share one `nar/<hash>` object. And it **refuses to
start if a single narinfo could not be read** — the first version of the indexer got HTTP
403 for all 10 769 of them because Cloudflare blocks the default `Python-urllib` user
agent, and a script that folded that into "not found" would have reported a clean
"nothing to prune". Counting errors separately is what caught it.

`/var/log/nix-cache-drain.log` carries `nix copy`'s own multi-line output, deliberately
apart from `/var/log/nix-cache-push.log` so that it cannot break the
one-`printf`-per-record atomicity there.

**No daemon restart is needed for any of this**, and the reason is worth keeping: the
`post-build-hook` setting still reads exactly
`/run/current-system/sw/bin/nix-cache-post-build-hook`. Determinate's `nix-daemon` caches
that *string* at startup and execs it fresh per build, so changing the script's contents
takes effect with the switch. Renaming the hook, or pointing the setting at
`${hookScript}/bin/…`, would give that up.

What the split does **not** fix: the uplink is still the uplink, so a large closure still
takes minutes — it just takes them somewhere that nobody is waiting. If the queue is
never empty, that is the signal, and `just cache-queue` is how it gets noticed instead of
growing in silence.

### The public cache mirrors system closures, including non-redistributable binaries

This is by construction, not by oversight, and it is written down so nobody reads it
as an accident and "fixes" it with something that cannot work.

`nix-cache-push` filters only the **starting set** (the large-FOD filter). `nix copy`
then expands each path to its **closure**, because a binary cache has to be
referentially complete — the script's own comment records the error you get otherwise
(`cannot add '…-etc' … because the reference '…-chfn.pam' is not valid`). Everything
in those closures that R2 lacks is uploaded and re-signed with our key, whether it was
built here or substituted from somewhere else. Measured 2026-09-02:
`bash-5.3p15` sits in R2 while `nix path-info --json` reports `ultimate: false` and its
two `cache.nixos.org` signatures — purely substituted here, then re-published by a
closure push.

So the bucket ends up holding whatever these systems use. Some of that is prebuilt
vendor binaries whose licence carries **`meta.license.redistributable = false`**. Which
ones is deliberately not written here: the mechanism is the point, and a list would be
a pointer.

**A push-side exclusion list cannot prevent it.** A home-manager-generated wrapper
around such a package carries `allowSubstitutes = ""` and `preferLocalBuild = 1`, so it
is always built locally on every host, and it *references* the package — dropping the
package from the starting set just means the wrapper's closure carries it. Dropping the
wrapper does not help either, because `home-manager-path` references the wrapper.
Fixing a substituter so the package is fetched rather than built saves the build and
the download, and changes nothing about this.

**A licence filter cannot work, and would fail in a way that reads as success.**
`meta.license` is eval-time data and is not recorded in the store, as the VS Code
passage above already states. Worse, the obvious predicate is the wrong one: one of the
flake inputs here deliberately overrides nixpkgs' unfree licence with `free = true` so
consumers need no `allowUnfree`, so its packages evaluate as `meta.unfree = false` and
`meta.license.free = true`, and only `meta.license.redistributable = false` expresses
the restriction. A filter keyed on `unfree` would report clean while publishing them.
That is a different category from VS Code, which is genuinely `meta.unfree = true`.

**Deleting objects has a trap, but a smaller one than this section used to claim.**
narinfo 200s are edge-cached for 30 days (`infra/src/index.ts`), so removing objects
without purging the Cloudflare cache leaves a 200 narinfo pointing at a missing NAR for up
to a month. What that actually does was measured on 03.09.2026, by building a local
`file://` cache in exactly that state:

```
warning: file 'nar/….nar.xz' does not exist in binary cache
copying path '/nix/store/…' from 'file:///…/good'...          <- fell through, exit 0
```

**Nix warns and falls back to the next substituter.** Only when the broken cache is the
*only* source does it report `no substituter that can build it` — and at that point Nix
builds the path locally, which for the per-project outputs this concerns is what would
have happened anyway. So it degrades to a warning plus a rebuild, not to a broken system.
A Cloudflare purge closes the window immediately but needs a token with Zone.Cache Purge,
which is not on these machines. And the next `just switch` re-pushes the current version
anyway, so deletion is only useful for something the push side now filters.

The only durable change would be to stop serving the bucket publicly. Deliberately not
done: both Macs and `p-ion-berlin-xs56r6` substitute from it, and `just bootstrap`
depends on it being open to a machine that has no credentials yet.

Decided 2026-09-02 to document rather than remove, with one piece of perspective on the
record: the binaries this concerns are themselves served **unauthenticated** from their
vendors' own download hosts — that is where this repo fetches them — so the question is
redistribution, not secrecy. Weigh any future addition to this cache on that basis, and
keep in mind that store hashes are derivable by anyone who evaluates this public flake.

