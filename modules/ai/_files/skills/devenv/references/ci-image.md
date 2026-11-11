# CI Image — Green on the Mac, Red in CI

Goal: a test or script that passes locally must not fail in the nix-based devenv CI image
(`ghcr.io/cachix/devenv/devenv`, pinned by digest, the pipeline running
`devenv shell -- <ci-script>`) because something the Mac happens to have is missing there.

Measured on 2026-11-11 in one project, against the pinned image (devenv 2.1.2,
aarch64-linux natively under OrbStack; the pipeline runs the same digest on amd64).
Re-measure after an image bump.

## 1. The trap

A developer's Mac answers almost every `command -v` — the login shell carries everything
from nix-darwin and Homebrew, plus `/bin/bash` and `/usr/bin/perl` from macOS itself.
The CI image has the stdenv tools and what `packages` lists, and nothing else. Measured
inside `devenv shell` in the image, with a `devenv.nix` of `packages = [ ];`:

| what the script used | Mac | CI image | how it failed |
|---|---|---|---|
| shebang `#!/bin/bash` | ok | **no `/bin/bash`** | `bad interpreter: No such file or directory`, exit 126 |
| shebang `#!/usr/bin/env bash` | ok | ok | — |
| `perl` | ok | **missing** | exit 127 |
| `zstd` | ok | **missing** | tests guarded by `shutil.which("zstd")` **skipped silently** |
| `sed`, `awk`, `grep`, `find`, `env` | ok | ok (stdenv: GNU) | — |
| `pgrep`, `pkill`, `ps` | ok | BusyBox, from the image's own profile | see below |

None of this showed locally, and it did not show all at once in CI either: the first two
failures came first, and the next one only after they were fixed. Each round trip through
the pipeline found one layer.

**`pgrep`/`pkill` are BusyBox there, not procps.** The image's user profile is on `PATH`
and `devenv shell` inherits that `PATH`, so `pgrep -P` exists and worked in a direct probe.
Whether a CI step sees it depends on the `PATH` the runner passes in — not verified here.
Two tests that kill a process tree with `pgrep -P` failed in CI and were first blamed on
the missing procps; reproduced in the image with BusyBox `pgrep` present, the same two
still failed, 2 runs of 2. The cause was the zombie trap of section 3. Avoid the tool
anyway (section 2), but do not stop looking once it is gone.

Rule: **whatever a script or test calls that is not in `devenv.nix` `packages` and not part
of the stdenv (bash, coreutils, sed, find, awk, grep) is not guaranteed in CI.**

## 2. The fix, in order of preference

1. **Avoid the dependency.** Shebang `#!/usr/bin/env bash`, never `#!/bin/bash`. Instead of
   walking the tree with `pgrep -P`/`pkill -P`, start background jobs with `set -m` so each
   gets its own process group, and stop the group with `kill -- -<pgid>`. That needs no
   extra tool.
2. **Otherwise declare it** in `devenv.nix`, with a comment saying who needs it — the next
   person to tidy up `packages` cannot otherwise tell:

   ```nix
   packages = [
     # perl + zstd: scripts/foo.sh and its tests use both; without them the tests
     # fail (perl) or are skipped (zstd) in the CI image.
     pkgs.perl
     pkgs.zstd
   ];
   ```

   `pkgs.procps` for real `pgrep`/`pkill`.
3. **A test that needs a tool must not skip quietly where the tool is guaranteed.** Skip
   on a laptop without it, fail loudly inside devenv (`DEVENV_ROOT` is set there), so a
   tool that drops out of `packages` turns the test red instead of grey:

   ```python
   pytestmark = pytest.mark.skipif(
       shutil.which("zstd") is None and not os.environ.get("DEVENV_ROOT"),
       reason="needs the zstd command",
   )
   ```

## 3. "The process is gone" — zombies when PID 1 does not reap

Even with process groups, two more tests failed in CI. They checked that a stopped process
had gone, with `os.kill(pid, 0)`. The CI container's PID 1 is a placeholder command
(`cat`, `sleep`) that never reaps orphans, so a dead child stays in the process table as a
zombie, and `kill -0` / `os.kill(pid, 0)` keeps reporting it alive. Measured in the pinned
image, an orphan one second after it exited:

| PID 1 | `/proc/<pid>/status` | `kill -0 <pid>` |
|---|---|---|
| `sleep 1000` | `State: Z (zombie)` | **exists** |
| `docker run --init` (docker-init) | gone | gone |

Invisible on macOS (orphans are reaped at once) and in `docker run … bash -c '…'`, where
PID 1 is bash and reaps. Fix in the test: read the state from `/proc/<pid>/status` and
count `Z` as gone; where there is no `/proc` (macOS), `os.kill(pid, 0)` alone is right.

```python
def gone(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    if not Path("/proc").exists():
        return False                   # macOS: kill -0 succeeded, so it is alive
    try:
        return Path(f"/proc/{pid}/status").read_text().split("State:")[1].split()[0] == "Z"
    except FileNotFoundError:
        return True                    # reaped between kill -0 and the read
```

Rule: **a test asserting "the process is gone" must count a zombie as gone.**

Measured in the project, pinned image, PID 1 `sleep`: before the fix 2 tests red in 3 of
4 runs and 1 in the fourth (the second one is timing-dependent); after it all 31 tests of
the module green, twice. Same result in `python:3.13-slim` with `sleep` as PID 1.

## 4. Testing before the push

Two stages. Both mount the work tree **read-only** and copy it into the container's temp
directory, so tests leave nothing behind in the work tree.

**(i) Fast — a plain Linux container.** Catches what macOS has and Debian lacks:

```bash
docker run -d --name ci-probe -v "$PWD":/repo:ro -w /repo python:3.13-slim sleep 1000
docker exec ci-probe bash -c 'cp -r /repo /tmp/r && cd /tmp/r \
  && pip install -q pytest … && python -m pytest <paths>'
docker rm -f ci-probe
```

`python:3.13-slim` has no procps but does have bash and perl, so it catches
`pgrep`/`pkill`, **not** a missing `perl` or `/bin/bash`. Measured: `pgrep` absent, 46
tests passed. `sleep` as PID 1 is deliberate — with `docker run --rm … bash -c '…'` bash
is PID 1, reaps, and hides the zombie trap of section 3.

**(ii) Exact — the pinned devenv image itself**, same digest as the pipeline, without its
`/bin/bash`-less entrypoint, as root, with `HOME` set (the image has no `/root`):

```bash
IMG='ghcr.io/cachix/devenv/devenv@sha256:<digest from the pipeline>'
docker run -d --name ci-devenv -u root:root -e HOME=/tmp/home --entrypoint '' \
  -v "$PWD":/repo:ro -w /repo "$IMG" sleep 3000
docker exec ci-devenv bash -c 'mkdir -p /tmp/home && cp -r /repo /tmp/r && cd /tmp/r \
  && rm -rf .git .devenv .venv && git init -q && git add -A \
  && git config --global --add safe.directory "*" \
  && devenv shell -- <ci-script>'
docker rm -f ci-devenv
```

The image is 1.2 GB (pull: 37 s) and multi-arch, so it runs natively on Apple Silicon.
`rm -rf .git … git init` is needed in a git *worktree*, whose `.git` file points at a host
path that does not exist in the container (`fatal: not a git repository`, exit 128);
`.devenv`/`.venv` are dropped because they hold macOS binaries. `HOME` is kept out of the
copy so `.gitconfig` and caches do not land in the work tree.

Measured with the project's test script: first run including shell build, nixpkgs
download and `uv sync` a few minutes, the test run itself 57 s; 605 passed, 3 skipped,
3 deselected. The full CI script (lint and dependency scan as well) was **not** run in
the container.

## 5. Traps

- **A green Mac proves nothing about the CI image.** `/bin/bash`, `perl`, `zstd` and
  `pgrep`/`pkill` all exist locally and not (all) there.
- **A silently skipped test looks green.** Gate skips on `DEVENV_ROOT` (section 2).
- **`docker run --rm … bash -c` hides zombies**, because bash as PID 1 reaps. Use a
  non-reaping PID 1 (`sleep`) to match the CI runner.
- **`HOME` must be writable as root.** Without `-e HOME=…`, `git config --global` fails
  with `could not lock config file /root/.gitconfig`, exit 255.
