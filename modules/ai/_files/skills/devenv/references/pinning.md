# Pinning One Package to a Specific Version

Documentation:
- Pinning inputs: https://devenv.sh/pinning/
- Packages from another nixpkgs: https://devenv.sh/recipes/nix/
- Inputs (devenv.yaml): https://devenv.sh/inputs/

Goal: one package at an exact version — say duckdb 1.5.3 — while everything else keeps
following `nixpkgs`. The mechanism is a **second nixpkgs input pinned to a commit**, with
exactly one package taken from it. Do not repoint the `nixpkgs` input itself:
`github:cachix/devenv-nixpkgs/rolling` carries patches devenv relies on, and pinning it
would freeze every package at once.

Every number in this file was measured on 2026-09-10 with devenv 2.2.2 and Determinate
Nix 3.22.2 on aarch64-darwin. Re-measure rather than trust them after a major upgrade.

## 1. Find the commit that ships the version

nixhub.io lists every version a package ever had in nixpkgs, with the commit that
provides it. The website is HTML only; its backend is a JSON API — the one `devbox`
uses, `search.devbox.sh`, documented by Jetify as free for personal use:

```bash
curl -sS 'https://search.devbox.sh/v2/resolve?name=duckdb&version=1.5.3'
```

```json
{ "name": "duckdb", "version": "1.5.3",
  "systems": {
    "aarch64-darwin": {
      "flake_installable": {
        "ref": { "type": "github", "owner": "NixOS", "repo": "nixpkgs",
                 "rev": "35d3407a3816f3b341d8cf1d60abaf2b7b8166ac" },
        "attr_path": "duckdb" },
      "last_updated": "2026-07-15T11:37:32Z",
      "outputs": [ { "name": "out", "default": true,
                     "path": "/nix/store/96682ys3320p24jm96k2hwl4dfjgy7jf-duckdb-1.5.3" }, … ] },
    "aarch64-linux": { … "rev": "3889d66586e664adc76aa5c242331d3d71786187" … },
    "x86_64-linux":  { … "rev": "389ed85304b281ca7f306cf8a1eb4378651ca44e" … } } }
```

Two shortcuts, both wrappers around this API:

- nix-shell skill: `nix_shell.sh versions duckdb 1.5.3` prints the flake ref, the store
  path and whether cache.nixos.org has it; `nix_shell.sh versions duckdb` lists the history.
- MCP server `nixos`: `nix_versions {"package":"duckdb","version":"1.5.3"}` returns the
  commit and attribute only; `nix {"action":"cache","query":"duckdb","version":"1.5.3",
  "system":"aarch64-darwin"}` returns the cache status.

Endpoints: `v2/search?q=<term>` (names), `v2/pkg?name=<attr>` (full history, every
system), `v2/resolve?name=<attr>&version=<v>`. `version=latest` works, and so does a
prefix (`1.5` resolves to the newest 1.5.x). An unknown version answers **HTTP 404 with
a plain-text body, not JSON**. Rate limit: a pool of 1000 requests per IP address,
refilled at 5 per minute, then HTTP 429.

**Read the commit for what it is.** nixhub records, per system, the *last* commit at
which its crawler saw the version — not the commit that bumped it. `duckdb: 1.5.2 ->
1.5.3` was `8007e967`, merged 2026-06-11; nixhub names `35d3407a` (2026-07-15) for
darwin and `389ed853` (2026-07-08) for x86_64-linux. Taking the **newest** of the listed
commits gives the version on every system: measured, `35d3407a` evaluates to duckdb
1.5.3 for aarch64-darwin, x86_64-linux and aarch64-linux, and all three output paths
are on cache.nixos.org. A system missing from the list was never built for that
version — x86_64-darwin is absent from 1.5.3 because nixpkgs 26.11 dropped it.

## 2. Check the cache BEFORE pinning

A pin only pays off if Nix downloads the result instead of compiling it. The cheapest
check needs no nixpkgs evaluation at all: the API already names the store path, and a
binary cache answers for a path with one HEAD request:

```bash
# hash = the first 32 characters of the store path's basename
curl -sS -o /dev/null -w '%{http_code}\n' -I \
  https://cache.nixos.org/96682ys3320p24jm96k2hwl4dfjgy7jf.narinfo      # 200 = cached
```

Measured across duckdb 1.0.0 … 1.5.4 on every listed system: 14 of 14 paths answered
200. cache.nixos.org keeps what Hydra built, so old pins stay cheap.

Two other forms, and one trap:

- `nix path-info --store https://cache.nixos.org /nix/store/<path>` exits 0 when cached.
- `nix build --dry-run github:NixOS/nixpkgs/<rev>#duckdb` lists what would be fetched
  and what would be *built*. **It prints nothing when the path already exists locally**,
  which is not evidence of a cache hit — use one of the two checks above.

## 3. devenv.yaml and devenv.nix

```yaml
# devenv.yaml — the second input, pinned by commit; `nixpkgs` stays as it is
inputs:
  nixpkgs:
    url: github:cachix/devenv-nixpkgs/rolling
  nixpkgs-duckdb:
    url: github:NixOS/nixpkgs/35d3407a3816f3b341d8cf1d60abaf2b7b8166ac   # duckdb 1.5.3
```

**Variant A — take the one package directly:**

```nix
{ pkgs, inputs, ... }:
let
  pkgs-duckdb = import inputs.nixpkgs-duckdb { system = pkgs.stdenv.system; };
in
{
  packages = [ pkgs-duckdb.duckdb pkgs.jq ];   # jq still comes from `nixpkgs`
}
```

**Variant B — replace `pkgs.duckdb` everywhere** (devenv ≥ 1.5), for when other options
or modules read `pkgs.<name>`: `languages.<lang>.package`, `services.<svc>.package`, a
shared `devenv.nix` you would rather not edit:

```nix
{ pkgs, inputs, ... }:
let
  pkgs-duckdb = import inputs.nixpkgs-duckdb { system = pkgs.stdenv.system; };
in
{
  overlays = [ (final: prev: { duckdb = pkgs-duckdb.duckdb; }) ];
  packages = [ pkgs.duckdb ];
}
```

Both measured: `devenv shell -- duckdb --version` prints `v1.5.3`, and
`readlink -f "$(command -v duckdb)"` is exactly the store path the API named, so the
binary came from the cache. `import inputs.<name> { system = …; }` evaluates that nixpkgs
with its default config, which is what Hydra built; passing `config` or overlays that
change the package's *dependencies* changes its hash and forfeits the cache hit.

## 4. What the second input costs

| | measured |
|---|---|
| nixpkgs tarball download, once per pinned commit | 52 MB |
| unpacked source in the store | 328 MiB |
| extra evaluation time (`nix eval`, eval cache off, 5 runs each) | 0.98–1.24 s against 0.91–0.98 s: well under half a second |
| first `devenv shell` (downloads both nixpkgs, evaluates) | 3 min 3 s |
| second `devenv shell -- true` (evaluation cached) | 0.48 s |
| extra closure on x86_64-linux, duckdb 1.5.3 beside 1.5.5 from current nixpkgs | 7 paths, 199.5 MiB, **none shared** — its own glibc, openssl, … |
| extra closure on aarch64-darwin | 1 path, 59.7 MiB (system libraries are not store paths) |

All of that is download, not compilation, as long as section 2 said "cached".

## 5. Moving or removing the pin

`devenv update` re-resolves every input from `devenv.yaml`; a URL that carries a commit
resolves to that same commit again. Measured: after `devenv update`, `nixpkgs-duckdb`
still sat at `35d3407a` in `devenv.lock`. To move the pin, change the commit in
`devenv.yaml` and run `devenv update nixpkgs-duckdb`. To drop it, delete the input and
the `let` binding; the next `devenv update` prunes the lock entry.

## 6. The alternative — override the source — and why it usually loses

```nix
packages = [
  (pkgs.duckdb.overrideAttrs (old: {
    version = "1.5.3";
    src = pkgs.fetchFromGitHub {
      owner = "duckdb"; repo = "duckdb"; tag = "v1.5.3"; hash = "sha256-…";
    };
  }))
];
```

| | second input (this file) | `overrideAttrs` |
|---|---|---|
| binary | downloaded from cache.nixos.org | **always compiled locally** — the hash is new to every cache |
| closure | the pinned commit's dependencies, ~200 MiB extra on Linux | current dependencies, nothing extra |
| survives an upstream recipe change | yes, the recipe is pinned with the source | no: patches, flags and dependencies come from the *current* recipe and may not fit the old source |
| moving the version | one commit hash | version, hash, and whatever the recipe reads from the source (duckdb keeps `rev` and `hash` in `versions.json`) |

Reach for `overrideAttrs` only when the version you need is *newer* than any nixpkgs
commit has, so there is nothing to pin.

## 7. Traps

- **A pin in an imported `devenv.yaml` does nothing.** Imported projects contribute their
  `devenv.nix` only; their `devenv.yaml` is not evaluated (cachix/devenv#2205). The input
  belongs in the consuming project's own `devenv.yaml`.
- **Inside a flake devShell, `devenv` on `PATH` may be the flake-integration wrapper.**
  It offers only `tasks`, `test`, `up` and `version`, and `devenv shell -- …` prints that
  usage instead of running anything. `which -a devenv` shows both; call the real CLI by
  its full path.
- **`nix build --dry-run` is silent when the path is already local** — see section 2.
- **Do not `follows` the pinned input to `nixpkgs`.** That is the pin being undone; the
  two inputs are meant to differ.
