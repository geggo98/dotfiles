"""+vscode-ext: cooled, profile-scoped VS Code extension installs.

Installed by modules/vscode.nix next to scripts/supply-chain.py and
scripts/supply-chain.toml (this file loads the former by path and the latter is read
through it), so the cooldown is read from [cooldown] extensions in that manifest and
nowhere else. Callers, agents included, never pass a version or a number of days.

    +vscode-ext scan    [--profile P] (ID… | --from-repo DIR)   what would happen
    +vscode-ext install [--profile P] (ID… | --from-repo DIR)   do it
    +vscode-ext install --global ID…        the default profile AND every profile; only
                                            ids that modules/vscode.nix declares shared
    +vscode-ext list    [--profile P]
    +vscode-ext prune   [--profile P]                           drop what was installed
    +vscode-ext profile create NAME                             VS Code must be closed
    +vscode-ext open    [--profile P] DIR
    +vscode-ext status

WHY NOT `code --install-extension`. It honours exactly one version. Whatever the
extension pulls in with it, a pack's members or `extensionDependencies`, arrives in the
NEWEST version. Measured 2026-11-05: ms-python.python@2026.10.0 brought
ms-python.vscode-python-envs 1.42.0 along, one day old and never reviewed. A later
install never upgrades a member that is already present, but the python/debugpy pair
depend on each other, so no install order avoids it, and `--donot-include-pack-and-
dependencies` is not a known option (VS Code 1.145.0 passes it on to Electron). A local
.vsix pulls dependencies in just the same. So this tool does what the CLI does itself,
minus the dependency walk: it resolves the closure with `supply-chain.py extension-pick`,
downloads each .vsix, checks it against the SHA-256 the Marketplace publishes, unpacks it
and registers it in the profile's extensions.json. VS Code accepts that (measured: it
installs nothing else, and `--uninstall-extension` removes it), but ONLY if the entry has
no `relativeLocation`: VS Code resolves a non-empty one against ~/.vscode/extensions and
ignores `location`. `code --list-extensions` lists such an entry anyway, so listing proves
nothing; verify() resolves each entry the way VS Code does and requires its package.json.

WHERE THINGS LIVE. Extensions go to ~/.vscode/extensions-profiles, never to
~/.vscode/extensions: +vscode-regen-extensions rebuilds the DEFAULT profile from a
directory scan of the latter, and measured, that scan adopts every extension any profile
put there. Profile registration needs `storage.json`; VS Code rewrites that file on exit,
so a profile is only ever created while VS Code is closed.

Exit codes: 0 done or nothing to do, 1 something failed, 2 usage or environment,
75 another run holds the lock, 130/143 interrupted.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import importlib.util
import io
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import time
import urllib.request
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

HOME = Path(os.environ.get("HOME", "~")).expanduser()
USER_DIR = HOME / "Library/Application Support/Code/User"
STORAGE = USER_DIR / "globalStorage/storage.json"
PROFILES_DIR = USER_DIR / "profiles"
ROOT = HOME / ".vscode/extensions-profiles"
NIX_SIDECAR = ROOT / ".nix-profiles.json"          # written by the Nix activation
NIX_GENERAL = HOME / ".vscode/extensions/.nix-managed-extensions.json"
SHARED_SIDECAR = ROOT / ".shared-extensions.json"   # written by vscode_profiles.py
DEFAULT_REGISTRY = HOME / ".vscode/extensions/extensions.json"
LOCK = ROOT / ".vscode-ext.lock"
STATUS = ROOT / ".vscode-ext.status"
DEFAULT_PROFILE = "oneoff"
FLAGS = {"settings": True, "keybindings": True, "snippets": True, "tasks": True,
         "mcp": True}
PROFILE_NAME = re.compile(r"^[a-z0-9][a-z0-9_-]{0,30}$")
MAX_VSIX = 600 * 1024 * 1024
UA = "vscode-ext (nix-darwin config)"

SUCCESS, SKIP, ERROR, CLEANUP = "ok", "skip", "error", "cleanup"


class Fail(Exception):
    """A per-item failure: counted as ERROR, the run continues."""


class Usage(Exception):
    """Environment or usage problem: exit 2."""


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


# ---------------------------------------------------------------- supply-chain module

def load_sc():
    path = Path(__file__).resolve().with_name("supply-chain.py")
    if not path.exists():
        raise Usage(f"supply-chain.py not found next to {__file__}")
    spec = importlib.util.spec_from_file_location("supply_chain", path)
    if spec is None or spec.loader is None:
        raise Usage(f"cannot load {path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# --------------------------------------------------------------------------- JSONC

def strip_jsonc(text: str) -> str:
    """Comments and trailing commas out, strings untouched.

    .vscode/extensions.json is JSONC and in practice carries both. A regex over the whole
    text would also eat `//` inside a URL string, so this walks the text once.
    """
    out: list[str] = []
    i, n = 0, len(text)
    pending_comma = -1          # index in `out` of a comma that may turn out trailing
    while i < n:
        c = text[i]
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            out.append(text[i:j + 1])
            pending_comma = -1
            i = j + 1
        elif text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2
        elif c == ",":
            pending_comma = len(out)
            out.append(c)
            i += 1
        elif c in "}]":
            if pending_comma >= 0:
                out[pending_comma] = ""
            pending_comma = -1
            out.append(c)
            i += 1
        else:
            if not c.isspace():
                pending_comma = -1
            out.append(c)
            i += 1
    return "".join(out)


def read_recommendations(repo: Path) -> tuple[list[str], list[str]]:
    f = repo / ".vscode/extensions.json"
    if not f.exists():
        raise Usage(f"{f} does not exist")
    try:
        d = json.loads(strip_jsonc(f.read_text()))
    except json.JSONDecodeError as e:
        raise Usage(f"{f} is not valid JSONC: {e}")
    return list(d.get("recommendations") or []), list(d.get("unwantedRecommendations") or [])


# ------------------------------------------------------------------- VS Code state

def code_bin() -> str:
    for c in (HOME / "Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
              Path("/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code")):
        if c.exists():
            return str(c)
    found = shutil.which("code")
    if found:
        return found
    raise Usage("VS Code not found (looked in ~/Applications, /Applications and PATH)")


def vscode_running() -> bool:
    return subprocess.run(["pgrep", "-x", "Code"], capture_output=True).returncode == 0


def read_json(path: Path, default):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return default
    except json.JSONDecodeError as e:
        raise Usage(f"{path} is not valid JSON: {e}")


def write_json_atomic(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f"{path.name}.tmp.{os.getpid()}")
    tmp.write_text(json.dumps(data))
    os.replace(tmp, path)


def registered_profiles() -> dict[str, str]:
    """{name: location} from storage.json."""
    d = read_json(STORAGE, {})
    return {p["name"]: p.get("location", p["name"]) for p in d.get("userDataProfiles", [])}


def nix_profiles() -> set[str]:
    return set(read_json(NIX_SIDECAR, {}).get("profiles", []))


def nix_general_ids() -> set[str]:
    return {e["identifier"]["id"].lower() for e in read_json(NIX_GENERAL, [])}


def shared_ids() -> set[str]:
    """Extensions that modules/vscode.nix declares as shared by every profile."""
    return {i.lower() for i in read_json(SHARED_SIDECAR, {}).get("ids", [])}


def profile_file(name: str) -> Path:
    loc = registered_profiles().get(name)
    if loc is None:
        raise Usage(
            f"profile {name!r} is not registered. `code --profile` does not create one "
            f"for an install (measured: \"Profile '{name}' not found.\", exit 0). Create "
            f"it with VS Code closed: +vscode-ext profile create {name}")
    return PROFILES_DIR / loc / "extensions.json"


def entry_path(e: dict) -> str:
    return (e.get("location") or {}).get("fsPath") or (e.get("location") or {}).get("path") or ""


def is_nix(e: dict) -> bool:
    return entry_path(e).startswith("/nix/store/")


DEFAULT_EXT_ROOT = HOME / ".vscode/extensions"


def resolved_path(e: dict) -> str:
    """The directory VS Code will actually read for this entry: a non-empty
    `relativeLocation` wins and is taken relative to the DEFAULT extensions directory;
    only without one does `location` count."""
    rel = e.get("relativeLocation")
    return str(DEFAULT_EXT_ROOT / rel) if rel else entry_path(e)


def heal(entries: list[dict]) -> list[dict]:
    """Drop a `relativeLocation` that points somewhere other than the entry's real
    location, so entries written by an earlier version of this tool work."""
    for e in entries:
        loc = entry_path(e)
        if e.get("relativeLocation") and loc and \
                not loc.startswith(str(DEFAULT_EXT_ROOT) + "/"):
            e.pop("relativeLocation")
    return entries


def readable(e: dict) -> bool:
    return (Path(resolved_path(e)) / "package.json").is_file()


def check_writable(name: str) -> None:
    if name == "default" or name in nix_profiles():
        raise Usage(f"profile {name!r} is managed by Nix (or is the default profile); "
                    f"install into {DEFAULT_PROFILE!r} or a profile you created")


# ------------------------------------------------------------------ lock + progress

class Run:
    """Lock, signal flag, counters and a throttled progress line (rules in the global
    long-running-scripts rule: lines on stderr, rate from real work only)."""

    def __init__(self, total: int):
        self.total, self.n, self.t0 = total, 0, time.monotonic()
        self.counts = {SUCCESS: 0, SKIP: 0, ERROR: 0, CLEANUP: 0}
        self.stop: int | None = None
        self.last = 0.0

    def acquire(self) -> None:
        ROOT.mkdir(parents=True, exist_ok=True)
        self.lk = open(LOCK, "a")
        try:
            fcntl.flock(self.lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit(self._already())
        STATUS.write_text(f"pid={os.getpid()} start={time.ctime()}\n")
        for s in (signal.SIGINT, signal.SIGTERM):
            signal.signal(s, lambda sig, _frame: setattr(self, "stop", sig))

    @staticmethod
    def _already() -> int:
        st = STATUS.read_text().strip() if STATUS.exists() else "?"
        pid = re.search(r"pid=(\d+)", st)
        et = ""
        if pid:
            et = subprocess.run(["ps", "-o", "etime=", "-p", pid.group(1)],
                                capture_output=True, text=True).stdout.strip()
        log(f"already running: {st} (elapsed {et or '?'})")
        return 75

    def count(self, kind: str, label: str, note: str = "") -> None:
        self.counts[kind] += 1
        self.n += 1
        log(f"  {kind.upper():7} {label}{(' — ' + note) if note else ''}")
        self._progress()

    def _progress(self) -> None:
        now = time.monotonic()
        if now - self.last < 1 and self.n != self.total:
            return
        self.last = now
        el = now - self.t0
        done = self.counts[SUCCESS]            # SKIPs do not count towards the rate
        rate = done / el if el > 0 else 0
        eta = f"{(self.total - self.n) / rate:.0f}s" if rate else "?"
        log(f"{self.n}/{self.total}  {rate:.2f}/s  ETA {eta}  elapsed {el:.0f}s")

    def summary(self) -> int:
        lk = getattr(self, "lk", None)
        if lk is not None:                      # release the lock as soon as the work is done
            lk.close()
        left = self.total - self.n
        c = self.counts
        tail = " — interrupted" if self.stop else (" — nothing left to do" if not left else "")
        log(f"{c[SUCCESS]} ok, {c[SKIP]} skip, {c[ERROR]} error, {c[CLEANUP]} cleanup, "
            f"{left} left{tail}")
        if self.stop:
            return 128 + self.stop
        return 1 if c[ERROR] else 0


# ----------------------------------------------------------------------- install

def download(url: str, expect_sha: str | None) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": UA,
                                               "Accept-Encoding": "identity"})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            data = r.read(MAX_VSIX + 1)
    except OSError as e:
        raise Fail(f"download failed: {e}")
    if len(data) > MAX_VSIX:
        raise Fail(f"download larger than {MAX_VSIX // 2**20} MiB, refusing")
    if not expect_sha:
        raise Fail("the Marketplace publishes no SHA-256 for this build; refusing to "
                   "install what cannot be checked")
    got = hashlib.sha256(data).hexdigest()
    if got != expect_sha.lower():
        raise Fail(f"SHA-256 mismatch: Marketplace says {expect_sha[:16]}…, "
                   f"download is {got[:16]}…")
    return data


def unpack(data: bytes, dest: Path, ext_id: str, version: str) -> None:
    """Unpack extension/ from the .vsix into dest (which must not exist yet)."""
    try:
        z = zipfile.ZipFile(io.BytesIO(data))
    except zipfile.BadZipFile as e:
        raise Fail(f"not a zip file: {e}")
    try:
        pkg = json.loads(z.read("extension/package.json"))
    except (KeyError, json.JSONDecodeError):
        raise Fail("no readable extension/package.json in the .vsix")
    got_id = f"{pkg.get('publisher', '')}.{pkg.get('name', '')}".lower()
    if got_id != ext_id.lower() or str(pkg.get("version")) != version:
        raise Fail(f"package.json says {got_id}@{pkg.get('version')}, expected "
                   f"{ext_id.lower()}@{version}")
    base = dest.resolve()
    for info in z.infolist():
        if not info.filename.startswith("extension/") or info.filename.endswith("/"):
            continue
        target = (dest / info.filename[len("extension/"):]).resolve()
        if base != target and base not in target.parents:
            raise Fail(f"unsafe path in .vsix: {info.filename}")
        target.parent.mkdir(parents=True, exist_ok=True)
        mode = info.external_attr >> 16
        if stat.S_ISLNK(mode):
            link = z.read(info).decode()
            if os.path.isabs(link) or ".." in Path(link).parts:
                raise Fail(f"unsafe symlink in .vsix: {info.filename} -> {link}")
            os.symlink(link, target)
            continue
        target.write_bytes(z.read(info))
        if mode & 0o111:                       # language servers ship executables
            target.chmod(0o755)


def dir_name(item: dict) -> str:
    plat = item["targetPlatform"]
    suffix = "" if plat == "universal" else f"-{plat}"
    return f"{item['id'].lower()}-{item['version']}{suffix}"


def install_item(item: dict, entries: list[dict], dest: Path | None = None) -> list[dict]:
    """Download, verify, unpack, publish atomically; return the new entry list.

    `dest` is the directory the extension ends up in: ~/.vscode/extensions-profiles for a
    profile, ~/.vscode/extensions for a global install."""
    dest = dest or ROOT
    dest.mkdir(parents=True, exist_ok=True)
    rel = dir_name(item)
    final = dest / rel
    tmp = ROOT / f".tmp.{os.getpid()}.{rel}"
    if tmp.exists():
        shutil.rmtree(tmp)
    try:
        unpack(download(item["vsixUrl"], item["sha256"]), tmp, item["id"], item["version"])
        if final.exists():
            shutil.rmtree(final)
        os.rename(tmp, final)
    finally:
        if tmp.exists():
            shutil.rmtree(tmp, ignore_errors=True)
    new = {
        "identifier": {"id": item["id"].lower()},
        "version": item["version"],
        "location": {"$mid": 1, "fsPath": str(final), "external": f"file://{final}",
                     "path": str(final), "scheme": "file"},
        # `relativeLocation` only for an extension inside ~/.vscode/extensions: VS Code resolves
        # a non-empty one against that directory and IGNORES `location`, so for an entry that
        # lives in ~/.vscode/extensions-profiles it would be read from a directory that does
        # not exist ("Unable to read file … package.json"). `--list-extensions` does not
        # notice; the Extensions view does.
        **({"relativeLocation": rel} if dest == DEFAULT_EXT_ROOT else {}),
        "metadata": {"installedTimestamp": int(time.time() * 1000), "pinned": True,
                     "source": "vsix", "isPreReleaseVersion": False,
                     "hasPreReleaseVersion": False,
                     "targetPlatform": item["targetPlatform"]},
    }
    keep = [e for e in entries if e["identifier"]["id"].lower() != item["id"].lower()]
    return keep + [new]


def candidates(args) -> list[str]:
    ids = list(args.ids or [])
    if args.from_repo:
        recs, unwanted = read_recommendations(Path(args.from_repo).expanduser())
        skip = {u.lower() for u in unwanted}
        ids += [r for r in recs if r.lower() not in skip]
    if not ids:
        raise Usage("give extension ids or --from-repo DIR")
    seen, out = set(), []
    for i in ids:
        if "." not in i:
            raise Usage(f"not a <publisher>.<name> id: {i!r}")
        if i.lower() not in seen:
            seen.add(i.lower())
            out.append(i)
    return out


def plan_for(sc, ids: list[str], installed: dict[str, dict], nixids: set[str]):
    """-> (table, plan, skips, blocked, days).

    plan    ordered install items, shared members once
    skips   (id, why) for requested ids with nothing to install
    blocked (id, why) for ids the cooldown or a withdrawal rules out; NOT installed,
            and never installed in some newer version
    table   (status, id, text) for display
    """
    manifest = sc.load_manifest()
    now = datetime.now(timezone.utc)
    days = manifest.get("cooldown", {}).get("extensions", 14)
    cutoff = now - timedelta(days=days)
    table, plan, skips, blocked, planned = [], [], [], [], set()
    for ext_id in ids:
        low = ext_id.lower()
        if low in nixids:
            skips.append((ext_id, "provided by Nix"))
            table.append(("skip", ext_id, "provided by Nix"))
            continue
        done: dict[str, dict] = {}
        try:
            sc.extension_closure(ext_id, cutoff, now, done)
        except sc.ToolError as e:
            blocked.append((ext_id, str(e)))
            table.append(("blocked", ext_id, str(e)))
            continue
        new, kept = [], []
        for it in done.values():
            lid = it["id"].lower()
            if lid in nixids:
                continue
            have = installed.get(lid)
            if have:
                if have["version"] != it["version"]:
                    kept.append(f"{it['id']}: installed {have['version']}, cooled pick "
                                f"{it['version']} — kept")
                continue
            if lid not in planned:
                planned.add(lid)
                plan.append(it)
                new.append(it)
        root = done[low]
        if not new:
            why = f"already installed ({root['version']})" if not kept else "; ".join(kept)
            skips.append((ext_id, why))
            table.append(("skip", ext_id, why))
            continue
        extra = [f"{n['id']}@{n['version']}" for n in new if n["id"].lower() != low]
        txt = (f"{root['version']}  {root['ageDays']}d old  "
               f"{'verified' if root['domainVerified'] else 'UNVERIFIED'} publisher  "
               f"{root['installs']:,} installs")
        if extra:
            txt += "  + pulled in, each cooled: " + ", ".join(extra)
        if kept:
            txt += "  [" + "; ".join(kept) + "]"
        table.append(("install", ext_id, txt))
    return table, plan, skips, blocked, days


def cmd_scan_install(args, do_install: bool) -> int:
    sc = load_sc()
    glob = getattr(args, "glob", False)
    dry = getattr(args, "dry_run", False)
    profile = "default" if glob else args.profile
    ids = candidates(args)
    if glob:
        undeclared = [i for i in ids if i.lower() not in shared_ids()]
        if undeclared:
            raise Usage(
                f"{', '.join(undeclared)}: not declared shared in modules/vscode.nix "
                f"(sharedRuntimeExtensions). A global install is a decision made there, "
                f"not on the command line; declared: {sorted(shared_ids()) or 'none'}")
        dest, pf = DEFAULT_EXT_ROOT, DEFAULT_REGISTRY
    else:
        if do_install:
            check_writable(profile)
        dest, pf = ROOT, profile_file(profile)
    entries = heal(read_json(pf, []))
    installed = {e["identifier"]["id"].lower(): e for e in entries}
    table, plan, skips, blocked, days = plan_for(sc, ids, installed, nix_general_ids())
    log(f"{'GLOBAL (default profile + every profile)' if glob else f'profile {profile!r}'}, "
        f"cooldown {days} days (scripts/supply-chain.toml)")
    for status, ext_id, text in table:
        if not do_install or dry or status == "install":   # skips and blocks are counted below
            log(f"  {status.upper():8} {ext_id}  {text}")
    if not do_install or dry:
        log(f"{len(plan)} to install, {len(skips)} skip, {len(blocked)} blocked"
            + (" (dry run)" if dry else ""))
        return 1 if blocked else 0

    run = Run(len(plan) + len(skips) + len(blocked))
    run.acquire()
    for old in ROOT.glob(".tmp.*"):            # leftovers of an interrupted run
        shutil.rmtree(old, ignore_errors=True)
        run.counts[CLEANUP] += 1
    for ext_id, why in skips:
        run.count(SKIP, ext_id, why)
    for ext_id, why in blocked:
        run.count(ERROR, ext_id, f"not installed: {why}")
    for item in plan:
        if run.stop:
            break
        label = f"{item['id']}@{item['version']} ({item['targetPlatform']})"
        try:
            entries = install_item(item, entries, dest)
            if not glob:                        # the default registry is VS Code's own file;
                write_json_atomic(pf, entries)  # a global install goes through the regen below
            run.count(SUCCESS, label)
        except Fail as e:
            run.count(ERROR, label, str(e))
    if glob and plan and not run.stop:
        adopt_global(run)
    if not run.stop:
        verify(profile, plan, run)
    code = run.summary()
    if plan and code == 0:
        log("windows that already use these profiles need `Developer: Reload Window`")
    return code


def adopt_global(run: Run) -> None:
    """Make VS Code's default profile adopt what was unpacked into ~/.vscode/extensions,
    then copy it into every other profile.

    The default registry is rebuilt from a directory scan by +vscode-regen-extensions (it
    deletes extensions.json and lets `code` rescan, which is the only way VS Code picks a
    new directory up; see docs/vscode.md); +vscode-profiles then mirrors the shared entries
    into the other profiles. Both are Nix-built and found through the environment, which
    the +vscode-ext wrapper sets. Exit 1 from either means "a human has to do something"
    and is reported, not fatal."""
    for var, what in (("VSCODE_REGEN_BIN", "regenerate the default profile"),
                      ("VSCODE_PROFILES_BIN", "mirror into the other profiles")):
        exe = os.environ.get(var)
        if not exe:
            log(f"  NOTE    {var} is not set; run the matching command by hand to {what}")
            continue
        res = subprocess.run([exe], capture_output=True, text=True, timeout=180)
        for line in (res.stdout + res.stderr).strip().splitlines()[-6:]:
            log(f"          {line}")
        if res.returncode:
            run.counts[ERROR] += 1
            log(f"  ERROR   {Path(exe).name} exited {res.returncode}; {what} did not complete")


def verify(profile: str, plan: list[dict], run: Run) -> None:
    """Ask VS Code, not our own files, what the profile now contains."""
    if not plan:
        return
    cmd = [code_bin(), "--list-extensions", "--show-versions"]
    if profile != "default":
        cmd[1:1] = ["--profile", profile]
    res = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    seen = {l.strip().lower() for l in res.stdout.splitlines() if "@" in l}
    # `--list-extensions` also lists entries whose directory VS Code cannot read (measured
    # 2026-11-05: it listed them while the Extensions view said "Unable to read file …
    # package.json"), so the listing proves little. Resolve each entry the way VS Code
    # does and require the manifest to be there.
    reg = DEFAULT_REGISTRY if profile == "default" else profile_file(profile)
    current = {e["identifier"]["id"].lower(): e for e in heal(read_json(reg, []))}
    for it in plan:
        want = f"{it['id']}@{it['version']}".lower()
        e = current.get(it["id"].lower())
        why = None
        if want not in seen:
            why = "written to the profile but VS Code does not list it"
        elif e is None or not readable(e):
            why = f"listed, but no package.json at {resolved_path(e) if e else '?'}"
        if why:
            run.counts[SUCCESS] -= 1
            run.counts[ERROR] += 1
            log(f"  ERROR   {want}: {why}")


def cmd_list(args) -> int:
    entries = heal(read_json(profile_file(args.profile), []))
    bad = 0
    for e in sorted(entries, key=lambda e: e["identifier"]["id"]):
        origin = "nix" if is_nix(e) else "installed"
        flag = "" if readable(e) else f"  [INVALID: no package.json at {resolved_path(e)}]"
        bad += bool(flag)
        print(f"{e['identifier']['id']}@{e['version']}  [{origin}]{flag}")
    return 1 if bad else 0


def cmd_prune(args) -> int:
    check_writable(args.profile)
    pf = profile_file(args.profile)
    entries = heal(read_json(pf, []))
    drop = [e for e in entries if not is_nix(e)]
    run = Run(len(drop))
    run.acquire()
    for e in drop:
        label = f"{e['identifier']['id']}@{e['version']}"
        p = Path(entry_path(e))
        if ROOT in p.parents and p.exists():
            shutil.rmtree(p, ignore_errors=True)
        run.count(SUCCESS, label)
    write_json_atomic(pf, [e for e in entries if is_nix(e)])
    return run.summary()


def cmd_profile_create(args) -> int:
    name = args.name
    if not PROFILE_NAME.match(name) or name == "default":
        raise Usage(f"profile name must match {PROFILE_NAME.pattern} and not be 'default'")
    known = registered_profiles()
    if name not in known:
        if vscode_running():
            raise Usage("VS Code is running and rewrites storage.json when it exits, which "
                        "would drop the new profile. Quit VS Code (Cmd+Q), then retry.")
        d = read_json(STORAGE, {})
        d.setdefault("userDataProfiles", []).append(
            {"name": name, "location": name, "useDefaultFlags": dict(FLAGS)})
        write_json_atomic(STORAGE, d)
    pdir = PROFILES_DIR / str(known.get(name) or name)
    pdir.mkdir(parents=True, exist_ok=True)
    (pdir / "globalStorage").mkdir(exist_ok=True)   # else VS Code logs SQLITE_CANTOPEN
    if not (pdir / "extensions.json").exists():
        write_json_atomic(pdir / "extensions.json", [])
    log(f"profile {name!r} ready: code --profile {name} <dir>")
    return 0


def cmd_open(args) -> int:
    profile_file(args.profile)                 # fails with the right hint if unknown
    code = code_bin()
    os.execv(code, [code, "--profile", args.profile, args.dir])


def cmd_status() -> int:
    ROOT.mkdir(parents=True, exist_ok=True)
    lk = open(LOCK, "a")
    try:
        fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        Run._already()
        return 0
    print("not running")
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="+vscode-ext", description=(__doc__ or "").split("\n\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)

    def common(sp, ids=False):
        sp.add_argument("--profile", default=DEFAULT_PROFILE,
                        help=f"target profile (default: {DEFAULT_PROFILE}; never 'default')")
        if ids:
            sp.add_argument("ids", nargs="*", metavar="ID", help="<publisher>.<name>")
            sp.add_argument("--from-repo", metavar="DIR",
                            help="take recommendations from DIR/.vscode/extensions.json")

    s = sub.add_parser("scan", help="show the cooled plan, change nothing")
    common(s, ids=True)
    i = sub.add_parser("install", help="install the cooled plan")
    common(i, ids=True)
    i.add_argument("--dry-run", action="store_true", help="same as scan")
    i.add_argument("--global", dest="glob", action="store_true",
                   help="install for the default profile and every profile; only ids that "
                        "modules/vscode.nix declares shared (ignores --profile)")
    common(sub.add_parser("list", help="extensions in the profile"))
    common(sub.add_parser("prune", help="remove everything that was installed here"))
    o = sub.add_parser("open", help="open DIR with the profile")
    o.add_argument("dir")
    common(o)
    pc = sub.add_parser("profile", help="profile management")
    psub = pc.add_subparsers(dest="pcmd", required=True)
    pcc = psub.add_parser("create")
    pcc.add_argument("name")
    sub.add_parser("status", help="is a run in progress?")

    args = p.parse_args(argv)
    try:
        if args.cmd == "scan":
            return cmd_scan_install(args, False)
        if args.cmd == "install":
            return cmd_scan_install(args, True)
        if args.cmd == "list":
            return cmd_list(args)
        if args.cmd == "prune":
            return cmd_prune(args)
        if args.cmd == "open":
            return cmd_open(args)
        if args.cmd == "profile":
            return cmd_profile_create(args)
        return cmd_status()
    except Usage as e:
        log(f"error: {e}")
        return 2
    except (subprocess.TimeoutExpired, OSError) as e:
        log(f"error: {e}")
        return 2


if __name__ == "__main__":
    sys.exit(main())
