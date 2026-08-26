# Nix-darwin configuration tasks
# Recipes are sandbox-safe for LLM agents (no sudo, non-destructive) EXCEPT
# `switch` / `switch-host`, which apply the system config, and `daemon-restart`,
# which restarts the nix-daemon — all three use sudo, so run them interactively
# yourself, not from an agent.

# Pass recipe arguments to shebang recipes as real positional params ($@/$1…),
# so variadic wrappers (e.g. `pulumi`) can forward them via "$@" without the
# word-splitting/globbing that raw `{{ args }}` interpolation would cause.
set positional-arguments

# Default: list available tasks
default:
    @just --list

# Warn if there are untracked files under modules/ or hosts/ — Nix flakes
# only see git-tracked files, so untracked changes are silently ignored
# by build/eval/check. Run `git add -N <paths>` to make them visible.
_check-untracked:
    #!/bin/zsh
    set -euo pipefail
    # matches: ?? modules/foo.nix   and   ?? hosts/FCX19GT9XR/secrets.nix
    # perl exits 0 on no match, so this needs no `|| true` under `set -e`.
    untracked=$(git status --porcelain | perl -ne 'print if m{^\?\? (?:modules|hosts)/}')
    if [ -n "$untracked" ]; then
        echo "WARNING: untracked files under modules/ or hosts/ — the flake will NOT see them." >&2
        echo "Stage them first:  git add -N <paths>" >&2
        echo "$untracked" >&2
    fi

# Run a developer shell
shell:
    nix develop --no-pure-eval

# Build the current host configuration (without applying)
build: _check-untracked
    #!/bin/zsh
    # pipefail is load-bearing: just's default shell is `sh -cu`, so a bare
    # `darwin-rebuild build … | ts` reports the exit status of *ts*, and a failing
    # build comes out green. Observed for real — a shellcheck error inside a
    # writeShellApplication failed the build while `just build` returned 0.
    set -euo pipefail
    time darwin-rebuild build --flake . --keep-going --keep-failed -L | ts

# Build a specific host configuration
build-host host: _check-untracked
    #!/bin/zsh
    set -euo pipefail   # see the note on `build` — without it `| ts` eats failures
    time nix build '.#darwinConfigurations.{{ host }}.system' --keep-going --keep-failed | ts

# --- Apply configuration, restart the daemon (needs sudo; interactive — NOT agent-safe) ---

# Apply THIS host's configuration. Selects the flake attr by hardware serial
# (IOPlatformSerialNumber) so a transiently drifted LocalHostName — macOS's
# "-2" Bonjour suffix on a name collision — can't break attr selection the way
# a bare `--flake .` does. Extra args are forwarded, e.g. `just switch --dry-run`.
switch *args:
    #!/bin/zsh
    set -euo pipefail
    # matches:       "IOPlatformSerialNumber" = "FCX19GT9XR"   ->  $+{serial}
    # Anchored on the key name and the quoted value, not on a '"'-field index.
    serial=$(ioreg -c IOPlatformExpertDevice -d 2 | perl -ne '
        if (/"IOPlatformSerialNumber" \s* = \s* "(?<serial>[^"]+)"/x) {
            print $+{serial};
            last;
        }
    ')
    [ -n "$serial" ] || { echo "could not determine hardware serial" >&2; exit 1; }
    echo "→ sudo darwin-rebuild switch --flake .#${serial} $*" >&2
    sudo darwin-rebuild switch --flake ".#${serial}" "$@"

# Apply a SPECIFIC host by name, e.g. `just switch-host DKL6GDJ7X1`
switch-host host:
    sudo darwin-rebuild switch --flake ".#{{ host }}"

# Needed after a switch that changes a setting the daemon reads only at STARTUP,
# because `darwin-rebuild switch` writes the config without restarting it. Two
# such settings live in this repo: the R2 `post-build-hook` (modules/nix-cache.nix)
# and the Linux builders registered via `determinateNix.buildMachines`
# (modules/linux-builder.nix). Both fail SILENTLY until the restart — nothing is
# pushed, nothing is delegated, and no error says why — so restart rather than
# wait for a diagnosis.
#
# Restart the Determinate nix-daemon (after enabling the R2 hook or a builder)
daemon-restart:
    #!/bin/zsh
    set -euo pipefail
    echo "→ sudo launchctl kickstart -k system/systems.determinate.nix-daemon" >&2
    sudo launchctl kickstart -k system/systems.determinate.nix-daemon
    # `kickstart -k` returns once launchd has signalled the restart, not once the
    # daemon serves again — so ask the daemon itself instead of trusting the exit
    # code. Same reasoning as the builder's SSH handshake wait: a control plane
    # answering is not the service being ready.
    for i in {1..20}; do
        if nix store info --store daemon >/dev/null 2>&1; then
            nix store info --store daemon
            exit 0
        fi
        sleep 0.5
    done
    echo "nix-daemon did not answer within 10s." >&2
    echo "Inspect it with: launchctl print system/systems.determinate.nix-daemon" >&2
    exit 1

# Run flake checks
check: _check-untracked
    nix flake check

# Format all Nix files
fmt:
    nix run nixpkgs#nixpkgs-fmt -- $(find . -name '*.nix' -not -path './_*')

# Format and check — returns non-zero if files were changed
fmt-check:
    nix run nixpkgs#nixpkgs-fmt -- --check $(find . -name '*.nix' -not -path './_*')

# Update all mutable flake inputs — but never to code younger than the cooldown.
#
# `nix flake update` always jumps to the CURRENT branch head, which is exactly the
# window a supply-chain attack lives in. Measured 2026-08-22: a plain update moved six
# inputs to a HEAD committed the same day (worktrunk 0.1 days old, home-manager 0.2,
# llm-agents 0.3, devenv 0.5, determinate 0.6, nix-homebrew 0.8) while the
# ChainDrop/Shai-Hulud npm campaign was live. scripts/supply-chain.py resolves each
# input to the newest revision at least N days old instead. See the module docstring
# for why age beats scanning here (the poisoned ChainDrop tarballs had VALID SLSA L3
# provenance — the source was trojanized before the build).
#
# Policy lives in scripts/supply-chain.toml, not in these recipes: the cooldowns, the
# per-input overrides and the freeze list are all there, each with the measurement that
# justifies it. Same file drives `just audit`, so the check and the thing it checks
# cannot drift apart.
#
# Two behaviours worth knowing at the call site:
#   - nixpkgs channel branches are exempt AUTOMATICALLY and must stay that way: their
#     head is Hydra-gated and cache-covered, an intermediate commit is neither.
#   - an update never moves an input BACKWARDS. Raising a bar (e.g. llm-agents to 14 d)
#     leaves the locked rev alone and says how long until it clears on its own;
#     `--allow-rollback` forces the regression when that is genuinely wanted.
#
# Update all flake inputs, never to code younger than the cooldown
update *args:
    #!/bin/zsh
    set -euo pipefail
    python3 scripts/supply-chain.py update "$@"

# Show what `just update` would do, without touching flake.lock
update-preview *args:
    #!/bin/zsh
    set -euo pipefail
    python3 scripts/supply-chain.py update --dry-run "$@"

# Update a single flake input, still honouring the cooldown
update-input input:
    #!/bin/zsh
    set -euo pipefail
    python3 scripts/supply-chain.py --only "$1" update

# --- Supply-chain audit (read-only, agent-safe: no sudo, publishes nothing) ---
#
# Answers a DIFFERENT question from `just pulumi-audit`, and the two must not be
# conflated. pulumi-audit asks "is anything KNOWN-bad?" against OSV. This asks "is
# anything suspiciously NEW, or has upstream WITHDRAWN it?" — the question that
# actually mattered on 2026-08-04, when ChainDrop's poisoned tarballs carried valid
# npm provenance and SLSA L3 attestations and every scanner said clean.
#
# Three layers: flake inputs, tracked npm packages (an input's age bounds its contents
# only from below, and loosely), and VS Code extensions. Exit 1 on findings, 2 on error.
#
# Audit every layer: input ages, npm package ages, extension ages + withdrawals
audit *args:
    #!/bin/zsh
    set -euo pipefail
    python3 scripts/supply-chain.py audit "$@"

# Fast path — layer 1 only, no npm or marketplace lookups
audit-inputs:
    #!/bin/zsh
    set -euo pipefail
    python3 scripts/supply-chain.py audit --inputs-only

# Check VS Code extensions by id, e.g. `just audit-extensions rust-lang.rust-analyzer`.
# With no argument it reads [[extensions]] from scripts/supply-chain.toml. An extension
# that 404s is reported as WITHDRAWN, not as a skip — that is the evil-twin signal.
#
# Check VS Code extensions: old enough AND still published (ids, or the manifest list)
audit-extensions *ids:
    #!/bin/zsh
    set -euo pipefail
    args=()
    for id in "$@"; do args+=(--extension "$id"); done
    python3 scripts/supply-chain.py audit --extensions-only "${args[@]}"

# The third audit question, and again a different one. `just audit` asks "is anything
# suspiciously NEW or WITHDRAWN?"; `just pulumi-audit` asks "is anything KNOWN-bad?".
# This asks the dull one nobody asks until it bites: "does what I already trust still
# work?" Measured 2026-08-24 — an Atlassian token had expired 17 days earlier and the
# only symptom was Jira returning HTTP 404 on a real ticket, because Jira hides issue
# existence from unauthenticated callers. Classic ATATT3… tokens carry no readable
# expiry, so a probe is the only way to know. Reads files, prints accounts, never tokens.
# Exit 0 all good (skips included), 1 something no longer authenticates, 2 tool error.
#
# Check that long-lived credentials still authenticate (jira, confluence, bb)
creds-check *args:
    #!/bin/zsh
    set -euo pipefail
    python3 scripts/creds-check.py "$@"

# Escape hatch: update everything to branch HEAD, cooldown BYPASSED. For the case where
# you have decided, deliberately and with the reason written down, that you need code
# younger than the bar — a security fix that just landed, say. `just update` is the
# normal path; if you reach for this one, say why in the commit body.
#
# Update every input to branch HEAD — COOLDOWN BYPASSED, use deliberately
update-head:
    nix flake update

# Bump the pinned Homebrew source (brew-src in flake.nix) to the latest upstream
# release and relock. Homebrew 6 serves casks from a rolling JSON API that cannot
# be pinned, so a stale brew eventually meets a cask DSL artifact it doesn't know
# and `brew bundle` aborts activation — see the brew-src comment in flake.nix.
# This is the cure for that. Optional argument pins a specific tag instead.
brew-bump tag="":
    #!/bin/zsh
    set -euo pipefail
    tag="{{ tag }}"
    if [ -z "$tag" ]; then
        tag=$(curl -fsSL https://api.github.com/repos/Homebrew/brew/releases/latest | jq -r .tag_name)
    fi
    [ -n "$tag" ] && [ "$tag" != "null" ] || { echo "could not determine a brew tag" >&2; exit 1; }
    # matches:     url = "github:Homebrew/brew/6.0.17";   ->  $+{tag} eq "6.0.17"
    current=$(perl -ne '
        if (m{^ \s* url \s* = \s* "github:Homebrew/brew/(?<tag>[^"]+)"; \s* $}x) {
            print $+{tag};
            last;
        }
    ' flake.nix)
    [ -n "$current" ] || { echo "no brew-src url line found in flake.nix" >&2; exit 1; }
    if [ "$tag" = "$current" ]; then
        echo "brew-src already at $tag"
        exit 0
    fi
    echo "brew-src: $current -> $tag"
    # perl -i, not sed -i: Perl implements in-place editing itself, so it behaves
    # identically everywhere. `sed -i` does not — macOS puts BSD sed on PATH when
    # just runs without a loaded direnv, and BSD sed reads `-i'' -e` as "backup
    # extension -e", silently leaving a stale flake.nix-e beside the real file.
    # The END block makes a non-matching pattern a hard error instead of a no-op.
    # \Q…\E quotes the interpolated tag, so a dot in it stays a literal dot.
    # matches:     url = "github:Homebrew/brew/6.0.9";   (with CUR=6.0.9)
    CUR="$current" NEW="$tag" perl -i -pe '
        BEGIN { $n = 0 }
        $n += s|\Qurl = "github:Homebrew/brew/$ENV{CUR}";\E|url = "github:Homebrew/brew/$ENV{NEW}";|;
        END { die "substitution matched nothing — pattern drift in flake.nix?\n" unless $n }
    ' flake.nix
    nix flake update brew-src
    echo "Now run: just build && just switch   (switch selects the flake attr by hardware serial)"

# Recompute the agent-browser release-binary hashes for modules/agent-browser.nix
# after bumping the agent-browser-src tag in flake.nix. Prints the ready-to-paste
# `assets` attrset. Example: `just agent-browser-hashes 0.34.0`
agent-browser-hashes version:
    #!/bin/zsh
    set -euo pipefail
    base="https://github.com/vercel-labs/agent-browser/releases/download/v{{ version }}"
    for pair in aarch64-darwin:darwin-arm64 x86_64-darwin:darwin-x64 \
                x86_64-linux:linux-musl-x64 aarch64-linux:linux-musl-arm64; do
        sys="${pair%%:*}"
        asset="agent-browser-${pair##*:}"
        hash=$(nix store prefetch-file --json "$base/$asset" | nix run nixpkgs#jq -- -r .hash)
        printf '    %-14s = { asset = "%s"; hash = "%s"; };\n' "$sys" "$asset" "$hash"
    done

# Show what would change between current system and new build
diff: build
    nix store diff-closures /run/current-system ./result

# Build and verify no package DELTA — which is weaker than it sounds, and the
# gap has bitten: `nix store diff-closures` compares package names and versions,
# so a same-name package whose *contents* changed is invisible to it. Measured
# on the shells.nix split (22cafcc): the darwin-system derivation changed
# (7hkbppnc… -> msfspksx…) while this recipe reported "No differences". The
# generated config.fish had the same 155 lines in a different order.
#
# So: green here means "no package was added, removed or version-bumped". To
# prove content equality, compare the derivations instead:
#   nix eval --raw "git+file://$PWD?rev=$(git rev-parse HEAD~1)#darwinConfigurations.<host>.system.drvPath"
verify-no-diff: build
    #!/bin/zsh
    set -euo pipefail
    diff_output=$(nix store diff-closures /run/current-system ./result 2>&1)
    if [ -n "$diff_output" ]; then
        echo "Differences found:"
        echo "$diff_output"
        exit 1
    else
        echo "No differences — refactoring is safe."
    fi

# Show the flake dependency tree
deps:
    nix flake metadata --json | nix run nixpkgs#jq -- -r '.locks.nodes | to_entries[] | select(.value.locked?) | "\(.key): \(.value.locked.type):\(.value.locked.owner // ""):\(.value.locked.repo // "")"'

# Evaluate a flake output without building (fast syntax check)
eval: _check-untracked
    nix eval '.#darwinConfigurations' --apply 'x: builtins.attrNames x'

# Show derivation of current host build
show-derivation:
    nix derivation show '.#darwinConfigurations.FCX19GT9XR.system' | nix run nixpkgs#jq -- .

# --- VS Code ---

# That file is a read-only /nix/store symlink, so every writer fails with EACCES and
# retries on the next start: a schema migration for a setting whose TYPE changed
# upstream (extensions.autoUpdate went boolean -> "on"/"off"), Settings Sync pulling a
# change from the other Mac, an extension writing a default. None of it is visible
# outside the log, which is why this exists rather than a schema audit of the settings
# themselves — parsing VS Code's minified bundle would go stale with every release.
#
# Reads the NEWEST log session only, and refuses to call a session that predates the
# last switch clean: "VS Code has not started since" must not read as "nothing wrong".
#
# Has VS Code tried to write the Nix-managed settings.json? (reads the newest log)
vscode-settings-check:
    #!/bin/zsh
    set -euo pipefail
    logs="$HOME/Library/Application Support/Code/logs"
    settings="$HOME/Library/Application Support/Code/User/settings.json"

    if [[ ! -e "$settings" ]]; then
        echo "no settings at $settings — is programs.vscode enabled for this host?" >&2
        exit 2
    fi
    sessions=("$logs"/*(/N))          # zsh sorts globs; the names are timestamps
    if (( ${#sessions} == 0 )); then
        echo "no log sessions under $logs — VS Code has never run on this machine" >&2
        exit 2
    fi
    session="${sessions[-1]}"

    # home-manager re-creates the SYMLINK on every activation, so its own lstat mtime is
    # the time of the last switch. The target's mtime is a /nix/store path and is 1970.
    switched=$(perl -e 'print +(lstat($ARGV[0]))[9]' "$settings")
    started=$(perl -MTime::Local=timelocal_modern -e '
        # matches:  /…/Code/logs/20260826T183829/  ->  epoch seconds, local time
        # (the directory name is local time, which is why this is not timegm)
        $ARGV[0] =~ m{
            (?<y>\d{4}) (?<mo>\d{2}) (?<d>\d{2}) T
            (?<h>\d{2}) (?<mi>\d{2}) (?<s>\d{2})
        }x or die "unparsable log session name: $ARGV[0]\n";
        print timelocal_modern($+{s}, $+{mi}, $+{h}, $+{d}, $+{mo} - 1, $+{y});
    ' "$session")

    when=$(perl -e 'my @t = localtime($ARGV[0]); printf "%04d-%02d-%02d %02d:%02d:%02d",
        $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]' "$started")

    if (( started < switched )); then
        echo "newest log session ${session:t} ($when) predates the last switch — VS Code" >&2
        echo "has not started since. Inconclusive: start VS Code, then run this again." >&2
        exit 2
    fi

    files=("$session"/window*/renderer.log(N) "$session"/userDataSync.log(N))
    if (( ${#files} == 0 )); then
        echo "session ${session:t} ($when) holds no renderer.log or userDataSync.log" >&2
        exit 2
    fi

    matched=$(perl -ne 'print if m{Unable to write file .*/User/settings\.json}' "${files[@]}" || true)
    count=$(print -r -- "$matched" | perl -ne '$n++ if /\S/; END { print $n // 0 }')

    if (( count == 0 )); then
        echo "clean: no write attempts against settings.json in session ${session:t} ($when),"
        echo "across ${#files} log file(s). VS Code and the Nix-managed settings agree."
        exit 0
    fi

    echo "$count write attempt(s) against the read-only settings.json in session ${session:t} ($when):" >&2
    print -r -- "$matched" | perl -ne 'print if $. <= 3' | cut -c1-160 >&2
    echo "" >&2
    echo "Something wants a value the Nix config does not produce. Compare what VS Code" >&2
    echo "would save (Settings editor -> open settings.json, it shows the pending value)" >&2
    echo "against modules/vscode.nix, and check userDataSync.log for a Settings Sync loop." >&2
    exit 1

# --- Store maintenance ---

# Deduplicate the store by hard-linking identical files (safe, reversible)
optimise:
    nix store optimise

# The system profile is pruned automatically every week (see modules/nix-gc.nix);
# a one-off full sweep is `sudo nix-collect-garbage --delete-older-than 7d`.
#
# This also sweeps any RUNNING Linux builder back under its cap. Those stores
# live in Docker volumes that modules/nix-gc.nix's root daemon cannot reach —
# the OrbStack socket belongs to the login session, so a 03:00 daemon would fail
# exactly when nobody is watching. Stopped builders are skipped, not started.
#
# Collect user-level garbage (last 7 days) and sweep running Linux builders
gc:
    #!/bin/zsh
    set -euo pipefail
    nix-collect-garbage --delete-older-than 7d
    # Say why the builder sweep is being skipped. Exiting 0 in silence would make
    # "no builder running" and "never even looked" indistinguishable.
    if ! command -v docker >/dev/null 2>&1; then
        echo "docker not on PATH — skipping the Linux builder sweep" >&2
        exit 0
    fi
    if ! docker info >/dev/null 2>&1; then
        echo "docker daemon unreachable (OrbStack not running?) — skipping the Linux builder sweep" >&2
        exit 0
    fi
    for arch in x86_64 aarch64; do
        # No `docker inspect -f` here on purpose: its Go template braces are
        # also just's interpolation syntax, and just expands them inside recipe
        # bodies AND inside comments. --filter needs no template at all.
        if [ -n "$(docker ps --quiet --filter "name=^nix-linux-builder-$arch\$" --filter status=running)" ]; then
            zsh modules/_files/linux-builder/linux-builder gc --arch "$arch"
        fi
    done

# Decrypt and view the Boundary reference doc (hosts/DKL6GDJ7X1/BOUNDARY.md.gpg)
view-boundary-doc:
    gpg --decrypt hosts/DKL6GDJ7X1/BOUNDARY.md.gpg | less -R

# Edit the Boundary reference doc: decrypt -> $EDITOR -> re-encrypt to all three recipients
edit-boundary-doc:
    #!/bin/zsh
    set -euo pipefail
    tmp="$(mktemp -t BOUNDARY.md.XXXXXX)"
    trap 'rm -f "$tmp"' EXIT
    gpg --decrypt hosts/DKL6GDJ7X1/BOUNDARY.md.gpg > "$tmp"
    "${EDITOR:-nvim}" "$tmp"
    # --trust-model always: rely on the explicit recipient list rather than GPG's web-of-trust.
    # Necessary because the work check24 key has no WoT path to your primary key.
    gpg --yes --trust-model always --encrypt --armor \
        -r stefan@schwetschke.de \
        -r stefan.schwetschke@check24.de \
        -r stefan.schwetschke+DKL6GDJ7X1@check24.de \
        -o hosts/DKL6GDJ7X1/BOUNDARY.md.gpg "$tmp"

# Enter the devenv-backed developer shell (also available automatically via direnv)
devshell:
    nix develop --no-pure-eval

# --- Pulumi (infra/) ---

# Assert a secrets file can actually be opened by this machine's key, before sops runs.
#
# We decrypt with an SSH identity: SOPS_AGE_SSH_PRIVATE_KEY_FILE (exported from
# modules/shells.nix) points at ~/.ssh/id_ed25519_sops_nopw. In age, an SSH identity
# can ONLY open `ssh-ed25519` recipient blocks — never `age1` ones, even when the age1
# recipient is the ssh-to-age conversion of that very key. So a file carrying only
# age1 recipients is undecryptable here, and sops' own error does not say why: once
# SOPS_AGE_SSH_PRIVATE_KEY_FILE is set it drops out of the "did not find keys in
# locations" list, which reads as if it were never consulted at all.
_sops-preflight file:
    #!/bin/zsh
    set -euo pipefail
    f="{{ file }}"
    [ -r "$f" ] || { echo "sops preflight: cannot read $f" >&2; exit 1; }
    # matches:   recipient: ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA...   -> ssh
    #            recipient: age1vygfenpy584kvfdge57ep2...             -> age
    #            fp: B6CA7BD9B0973FBF981C3B1E7C8C077F1B72E98B         -> pgp
    read -r n_ssh n_age n_pgp <<<"$(perl -ne '
        $ssh++ if /^\s*-?\s*recipient:\s*ssh-ed25519\s/;
        $age++ if /^\s*-?\s*recipient:\s*age1[a-z0-9]/;
        $pgp++ if /^\s*-?\s*fp:\s*\S/;
        END { printf "%d %d %d", $ssh // 0, $age // 0, $pgp // 0 }
    ' "$f")"
    if [ "$n_ssh" -gt 0 ]; then exit 0; fi
    {
        echo "sops preflight FAILED: $f has no ssh-ed25519 recipient."
        echo "  in the file:  $n_ssh ssh-ed25519, $n_age age1, $n_pgp pgp"
        echo "  We decrypt with an SSH identity (SOPS_AGE_SSH_PRIVATE_KEY_FILE, set in"
        echo "  modules/shells.nix). In age an SSH identity can only open ssh-ed25519"
        echo "  blocks — never age1 ones, not even the ssh-to-age conversion of the same"
        echo "  key — so this file cannot be decrypted here."
        echo
        echo "  declared for this path in .sops.yaml:"
        # Filename travels through the environment, not shell interpolation, so a path
        # holding regex metacharacters cannot break the pattern (same idiom as the
        # brew-bump recipe below). Backslashes are stripped per line because .sops.yaml
        # stores the path as an escaped regex.
        # matches:   - path_regex: ^secrets/infra\.enc\.yaml$   (against secrets/infra.enc.yaml)
        SOPS_FILE="$f" perl -ne '
            (my $line = $_) =~ s/\\//g;
            $on = 1 if $line =~ /\Q$ENV{SOPS_FILE}\E/;
            if ($on) { print "    $_"; $on = 0 if /age:.*\]/ }
        ' .sops.yaml | perl -pe 's/", "/",\n        "/g' || true
        echo
        echo "  Fix — re-key the file to every recipient .sops.yaml declares:"
        echo "      sops updatekeys $f"
        echo "  (this also restores any missing pgp recovery key, not just the ssh ones)"
        echo
        echo "  sops version: $(sops --version 2>&1 | head -1)"
    } >&2
    exit 1

# Run any pulumi command in infra/ with the Pulumi Cloud + Cloudflare tokens from SOPS
pulumi *args: (_sops-preflight "secrets/infra.enc.yaml")
    #!/bin/zsh
    set -euo pipefail
    PULUMI_ACCESS_TOKEN="$(sops -d --extract '["pulumi_access_token"]' secrets/infra.enc.yaml)"
    export PULUMI_ACCESS_TOKEN
    # The default cloudflare provider (and CLI `pulumi import`) reads this env var.
    CLOUDFLARE_API_TOKEN="$(sops -d --extract '["cloudflare_api_token"]' secrets/infra.enc.yaml)"
    export CLOUDFLARE_API_TOKEN
    # AWS goes through the environment rather than ~/.aws/credentials, per
    # Architecture.md §2: infra secrets live in the pulumi process and nowhere
    # else. That is not just tidiness here — sops-nix writes the *C24 work*
    # profile to ~/.aws/credentials on this machine, so a file-based setup would
    # put two unrelated identities in one place and pick between them by
    # convention. Static env credentials outrank the shared file in the SDK
    # chain, but an AWS_PROFILE inherited from the caller would still redirect
    # the provider at that work profile. Unset it so the identity Pulumi uses is
    # decided here and nowhere else.
    AWS_ACCESS_KEY_ID="$(sops -d --extract '["aws_access_key_id"]' secrets/infra.enc.yaml)"
    AWS_SECRET_ACCESS_KEY="$(sops -d --extract '["aws_secret_access_key"]' secrets/infra.enc.yaml)"
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    unset AWS_PROFILE AWS_DEFAULT_PROFILE
    # Which stack to operate on. Unlike the backend (pinned in infra/Pulumi.yaml),
    # this cannot be declared in the project file — Pulumi's ProjectBackend carries
    # only `url`, and there is no default-stack key. Stack selection is otherwise
    # per-machine state in ~/.pulumi/workspaces/, which a fresh checkout lacks, so
    # every command dies with "no stack selected". PULUMI_STACK supplies it and
    # persists nothing. Non-clobbering, and an explicit `-s/--stack` still wins.
    #
    # Beware the misleading error: a stack name that does not exist reports
    # "no stack selected" rather than "no stack named 'x' found". If you see that
    # after this is set, the NAME is wrong, not the backend — run
    # `just pulumi stack ls` to see the real names, and use <org>/<stack> if the
    # stack lives under an organisation rather than your personal account.
    export PULUMI_STACK="${PULUMI_STACK:-prod}"
    cd infra
    # pulumi runs the compiled dist/index.js (see Pulumi.yaml `main`), so rebuild
    # it first — tsc is fast/incremental and keeps the program in sync. pulumi +
    # pnpm live in the devenv shell; fall back to it when not already active
    # (e.g. non-interactive `just` without a loaded direnv). Args are forwarded
    # via "$@" (see `set positional-arguments`), so quoting/whitespace survives.
    if command -v pulumi >/dev/null 2>&1 && command -v pnpm >/dev/null 2>&1; then
      pnpm run --silent build
      pulumi "$@"
    else
      nix develop ../ --no-pure-eval -c bash -euc 'pnpm run --silent build && pulumi "$@"' -- "$@"
    fi

# Preview infrastructure changes
pulumi-preview: (pulumi "preview")

# Apply infrastructure changes
pulumi-up: (pulumi "up")

# Show current infrastructure state
pulumi-stack: (pulumi "stack")

# Install infra dependencies
pulumi-install:
    #!/bin/zsh
    set -euo pipefail   # see the note on `build` — without it `| ts` eats failures
    cd infra && time pnpm install | ts

# Audit infra/pnpm-lock.yaml against OSV + npm publish dates (exits 1 on findings)
pulumi-audit *args:
    python3 infra/scripts/osv-audit.py "$@"

# --- Inventory of hosts Pulumi cannot manage ---

# The hosts in infra/src/inventory.ts have no provider and no API (see that file's
# header, and Architecture.md §11), so `pulumi preview` reconciles nothing about
# them: the recorded constants could drift arbitrarily far from the real machine
# and every Pulumi command would still report a clean stack. This is the only
# thing that can tell you otherwise. Fails on a host-key mismatch AND on an
# unreachable host — silence is never success.
#
# Verify infra/src/inventory.ts against the real hosts (reachable + host key matches)
infra-verify *args:
    python3 infra/scripts/infra-verify.py "$@"

# Fills the inventory and decides how deeply Nix can manage a host: system-manager
# on the existing distro, or a full NixOS conversion via nixos-anywhere. Changes
# nothing on the target; prints to stdout, so redirect to keep the result —
#   just infra-recon root@87.106.149.208 > /tmp/ionos-recon.txt
#
# The second half covers storage appliances (ZFS, TrueNAS middleware, SMART,
# dmidecode, clock, uplink) and collapses to a single line on a host that has
# none of it, so one command still answers for every host we own.
#
# Read-only SSH survey of an unprovisioned host (hardware, disks, network, services)
infra-recon target:
    #!/bin/zsh
    set -euo pipefail
    echo "# recon of $1 — read-only, no changes made"
    # BatchMode: fail fast instead of prompting, so a missing key is an error
    # rather than a hung recipe. accept-new (not `no`) because the point of this
    # run is often to learn the host key in the first place; `just infra-verify`
    # is what pins it afterwards.
    ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
        "$1" 'bash -s' <<'REMOTE'
    # Survey only. Every entry is a read; nothing here writes, installs or
    # restarts. A missing tool prints "(exit N)" rather than aborting the run —
    # for a survey "not present" is a real answer, not a swallowed failure.
    #
    # Output is captured rather than streamed for one reason: a command that
    # succeeds and prints nothing is otherwise indistinguishable from one that
    # was never run. `dmidecode -t17` on a board without SMBIOS does exactly
    # that, and an empty section under a heading reads like a checked box.
    run() {
      printf '\n### %s\n' "$1"
      out=$(sh -c "$2" 2>&1); rc=$?
      [ -n "$out" ] && printf '%s\n' "$out"
      [ "$rc" -ne 0 ] && printf '(exit %d)\n' "$rc"
      [ -z "$out" ] && [ "$rc" -eq 0 ] && printf '(no output)\n'
      return 0
    }

    run 'identity'        'hostnamectl; uname -a'
    run 'uptime / boot'   'uptime; who -b'
    run 'cpu + memory'    'nproc; free -m'
    run 'block devices'   'lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL'
    run 'partitions'      'sudo -n parted -l 2>/dev/null || parted -l 2>/dev/null || echo "(needs root)"'
    run 'filesystems'     'df -hT -x tmpfs -x devtmpfs'
    run 'fstab'           'cat /etc/fstab'
    # Interface name and both gateways decide the static network config a NixOS
    # install must carry: IONOS hands out a static IPv6 with a link-local gateway,
    # and a DHCP-only config comes back up without it.
    run 'addresses'       'ip -brief addr'
    run 'routes v4'       'ip route'
    run 'routes v6'       'ip -6 route'
    run 'netplan'         'cat /etc/netplan/*.yaml 2>/dev/null || echo "(no netplan)"'
    run 'dns'             'resolvectl status 2>/dev/null | head -30 || cat /etc/resolv.conf'
    run 'kexec support'   'test -e /sys/kernel/kexec_loaded && echo "kexec_loaded present" || echo "no /sys/kernel/kexec_loaded"; dpkg -l kexec-tools 2>/dev/null | tail -1'
    run 'running units'   'systemctl list-units --type=service --state=running --no-pager --no-legend'
    run 'listening ports' 'ss -tulpn 2>/dev/null || ss -tuln'
    run 'enabled at boot' 'systemctl list-unit-files --state=enabled --no-pager --no-legend'
    run 'containers'      'docker ps -a 2>/dev/null || echo "(no docker)"; podman ps -a 2>/dev/null || true'
    # What a NixOS conversion would destroy. Sizes only — no file contents.
    # Each path is tested before measuring: `du` exits non-zero if *any* argument
    # is missing, and an || fallback chain would then re-run and append a bogus
    # "(needs root)" after a perfectly complete listing. An absent directory is
    # reported as absent rather than silently dropped.
    run 'data footprint'  'for d in /home /srv /opt /var/www /var/lib /root /usr/local; do if [ -e "$d" ]; then du -shx "$d"; else printf -- "-\t%s (does not exist)\n" "$d"; fi; done'
    run 'human users'     'getent passwd | awk -F: "\$3 >= 1000 && \$3 < 65534"'
    run 'authorized_keys' 'wc -l /root/.ssh/authorized_keys ~/.ssh/authorized_keys 2>/dev/null || echo "(none readable)"'
    run 'cron / timers'   'ls -1 /etc/cron.d 2>/dev/null; systemctl list-timers --no-pager --no-legend 2>/dev/null | head -20'
    run 'nix present?'    'test -d /nix && echo "/nix exists" || echo "no /nix"'
    run 'package count'   'dpkg -l | grep -c "^ii" || true'

    # --- Storage appliance ---------------------------------------------------
    # Added for p-own-lengenwang-c5esve (TrueNAS SCALE, which *is* Debian, so
    # everything above applies). `have` short-circuits the whole block to one
    # line on a host without ZFS, rather than printing a wall of "(exit 127)" —
    # "not a ZFS host" is an answer, a column of failures is noise.
    have() { command -v "$1" >/dev/null 2>&1; }

    if have zpool; then
      # Topology decides the migration strategy before anything else does: a
      # mirror can be imported by the new system, a single-vdev pool that shares
      # its disk with the boot pool has to be copied out and back byte by byte.
      run 'zfs pools'      'zpool list -o name,size,alloc,free,frag,cap,health; echo; zpool status -v'
      run 'zfs datasets'   'zfs list -o name,used,avail,refer,compression,compressratio,encryption,keystatus,mountpoint'
      run 'zfs snapshots'  'zfs list -t snapshot -o name,used,refer,creation 2>/dev/null | head -50; printf "total snapshots: %s\n" "$(zfs list -t snapshot -H 2>/dev/null | wc -l)"'
      # The question to answer before any wipe. `keylocation=prompt` means the
      # key lives in the appliance keystore on the boot device — which a
      # reinstall destroys, taking the data with it even if the data survives.
      # A file:// path means it lives elsewhere, and that elsewhere becomes the
      # thing to guard.
      run 'zfs encryption' 'zfs get -o name,property,value encryption,keyformat,keylocation,encryptionroot,keystatus'
      # Which pool sits on which *partition*. `zpool status` alone names vdevs,
      # not devices, so two pools sharing one disk are invisible without -P.
      run 'zfs vdev paths' 'zpool status -P'
    else
      run 'zfs'            'echo "(no zpool — not a ZFS host)"'
    fi

    if have midclt; then
      # The appliance's own CLI. It answers as root over the local socket with
      # no API token, and it reports the *configured* state, which is what a
      # rebuild has to reproduce — `systemctl` only shows what happens to run.
      run 'truenas config' 'for c in system.info sharing.smb.query sharing.nfs.query service.query vm.query chart.release.query; do printf "\n-- %s\n" "$c"; midclt call "$c" 2>&1 | python3 -m json.tool 2>/dev/null || midclt call "$c" 2>&1; done'
    fi

    # --- Hardware, for infra/src/inventory.ts --------------------------------
    # dmidecode is the only source for the board part number: the appliance UI
    # shows the chassis string ("Super Server"), which identifies nothing.
    run 'board / bios'   'dmidecode -t1 -t2 -t3 2>/dev/null || echo "(needs root / no dmidecode)"'
    run 'memory'         'dmidecode -t16 -t17 2>/dev/null | grep -E "Maximum Capacity|Number Of Devices|Size:|Type:|Speed:|Part Number|Rank" | head -40'
    # Percentage Used and Data Units Written are the two numbers that turn
    # "replace it eventually" into a date, and neither is visible in any UI here.
    run 'disk health'    'nvme list 2>/dev/null; n=0; for d in /dev/nvme?n? /dev/sd? /dev/mmcblk?; do [ -e "$d" ] || continue; n=$((n+1)); printf "\n-- %s\n" "$d"; smartctl -a "$d" 2>&1 | grep -E "Model|Serial|Firmware|Capacity|Percentage Used|Data Units Written|Power On|Power_On|Temperature:|SMART overall" || echo "(smartctl gave nothing for $d)"; done; [ "$n" -eq 0 ] && echo "(no nvme/sd/mmcblk devices)"; true'
    # sysfs first, lsusb only as a bonus: `usbutils` is absent on a TrueNAS appliance
    # (and on plenty of minimal images), and "(no lsusb)" is a useless answer to
    # "what is plugged into this machine". sysfs is always there on Linux, and it is
    # what settles questions like "is that a USB stick or a KVM emulating one" --
    # a device claiming interface class 08 while its siblings are class 03 HID is a
    # KVM, not storage.
    run 'usb peripherals' 'for d in /sys/bus/usb/devices/*/; do [ -f "$d/idVendor" ] || continue; printf "%-12s %s:%s  %s | %s | %s\n" "$(basename $d)" "$(cat $d/idVendor)" "$(cat $d/idProduct)" "$(cat $d/manufacturer 2>/dev/null || echo -)" "$(cat $d/product 2>/dev/null || echo -)" "$(cat $d/serial 2>/dev/null || echo -)"; done; echo; for i in /sys/bus/usb/devices/*:*/; do [ -e "$i/bInterfaceClass" ] || continue; printf "  %-14s class=%s driver=%s\n" "$(basename $i)" "$(cat $i/bInterfaceClass)" "$(basename $(readlink $i/driver 2>/dev/null) 2>/dev/null || echo -)"; done; command -v lsusb >/dev/null && { echo; lsusb; }; true'
    run 'block devices+' 'lsblk -o NAME,SIZE,TRAN,TYPE,MODEL,SERIAL,MOUNTPOINT'
    # A clock more than 15 minutes out makes every S3 request fail with
    # RequestTimeTooSkewed. For a host that is about to push a backup into
    # object storage this is a precondition, not a detail.
    run 'clock'          'date -u; timedatectl 2>/dev/null; chronyc tracking 2>/dev/null || ntpq -p 2>/dev/null || echo "(no chrony/ntpq)"'
    run 'backup tools'   'for t in restic rclone borg kopia tmux screen python3; do printf "%-8s %s\n" "$t" "$(command -v $t || echo -)"; done'
    run 'k3s workloads'  'k3s kubectl get pods -A 2>/dev/null || echo "(no k3s)"'
    # Upload is what decides whether a cloud backup takes hours or weeks, and no
    # local measurement substitutes for it. Cloudflare's public speed endpoint
    # needs no credentials and receives zeros; nothing on the target changes.
    run 'uplink upload'  'command -v curl >/dev/null || { echo "(no curl)"; exit 0; }; dd if=/dev/zero bs=1M count=25 2>/dev/null | curl -s -o /dev/null -X POST --data-binary @- -w "upload %{speed_upload} B/s (%{size_upload} bytes in %{time_total} s)\n" https://speed.cloudflare.com/__up'
    REMOTE

# --- Nix binary cache (Cloudflare R2) ---

# Endpoint of the S3 push target (public pull URL is the custom domain).
R2_S3_URL := "s3://nix-cache?endpoint=81e63dbf073ca45ebf67c430beac09a4.r2.cloudflarestorage.com&region=auto&compression=zstd"

# Seed R2 with the current system's delta (paths not already on cache.nixos.org)
cache-seed:
    NIX_CACHE_S3_URL='{{ R2_S3_URL }}' zsh modules/_files/nix-cache/nix-cache-push --seed

# Push specific paths (repair/ad hoc), e.g. `just cache-push /run/current-system`
cache-push *paths:
    NIX_CACHE_S3_URL='{{ R2_S3_URL }}' zsh modules/_files/nix-cache/nix-cache-push "$@"

# Read the post-build-hook's push log. Every hook invocation leaves one line,
# successes included — so an empty log means the hook is not running, not that
# everything is fine. Optional argument filters, e.g. `just cache-log FAIL`.
cache-log filter="":
    #!/bin/zsh
    set -euo pipefail
    log=/var/log/nix-cache-push.log
    if [ ! -f "$log" ]; then
        echo "$log does not exist yet." >&2
        echo "The hook only starts writing after a switch AND a daemon restart:" >&2
        echo "  just daemon-restart" >&2
        exit 1
    fi
    if [ -z "{{ filter }}" ]; then
        tail -50 "$log"
        exit 0
    fi
    # grep's exit codes are load-bearing here: 1 means "no match", which for
    # `cache-log FAIL` is the *good* outcome and must not be reported as a
    # failure. Piping straight into tail under `set -o pipefail` did exactly
    # that — an empty failure list came out as "recipe failed with exit code 1".
    # 2-and-up stays an error, so a genuinely unreadable log is not swallowed.
    set +e
    matches=$(grep -- "{{ filter }}" "$log")
    rc=$?
    set -e
    case $rc in
        0) printf '%s\n' "$matches" | tail -50 ;;
        1) echo "no records matching '{{ filter }}'" >&2 ;;
        *) echo "grep failed on $log (exit $rc)" >&2; exit $rc ;;
    esac

# Seed R2 with a REMOTE host's closure delta, e.g. the x86_64-linux VPS. The R2
# write credentials stay here; the server has the cache as a read-only
# substituter and never holds a push key.
#   just cache-seed-remote root@87.106.149.208
#
# This was once the ONLY way x86_64-linux paths reached the cache, because those
# paths existed nowhere but the server. `just nixos-build` now produces them
# locally in Docker and pushes them, and this recipe is the fallback: adopting
# whatever a host built on its own — a `--build-on remote` install, or a
# derivation Rosetta could not handle.
#
# Seed R2 from a REMOTE host's store over ssh-ng
cache-seed-remote host target="/run/current-system":
    #!/bin/zsh
    set -euo pipefail
    # max-connections=1 is not tuning, it is correctness. `nix copy` otherwise
    # opens several SSH channels at once; sshd refuses the ones past its
    # MaxSessions limit, and the refused channel hands nix a few bytes of
    # multiplexer noise instead of a protocol greeting:
    #     error: cannot open connection to remote store 'ssh-ng://…':
    #            protocol mismatch, got 'started …'
    # The whole copy then aborts having transferred nothing. Serial is slower
    # and finishes.
    NIX_CACHE_S3_URL='{{ R2_S3_URL }}' zsh modules/_files/nix-cache/nix-cache-push \
      --from "ssh-ng://{{ host }}?max-connections=1" --seed "{{ target }}"

# Bootstrap a fresh machine: pre-fetch the R2-cached delta (the paths NOT on
# cache.nixos.org) into the store BEFORE the first switch, so that first —
# otherwise most expensive — build downloads them instead of compiling from
# source. Needs sudo: on a fresh box the login user isn't a trusted-user yet
# (that only lands at the first activation) and nix.custom.conf doesn't exist,
# so only a root (always-trusted) invocation with explicit flags makes the
# daemon honor R2. Then apply the printed switch. Example: `just bootstrap DKL6GDJ7X1`
bootstrap host:
    #!/bin/zsh
    set -euo pipefail
    sudo nix build --no-link \
      --extra-substituters 'https://nix-cache.pub.schwetschke.dev' \
      --extra-trusted-public-keys 'nix-cache.pub.schwetschke.dev-1:R3UAHtpY90nzsAtEm3LDaWsEAHYQK6YG+i8mYxTgL10=' \
      '.#darwinConfigurations.{{ host }}.system'
    echo
    echo "R2 delta is in the local store. Now apply it:"
    echo "  just switch-host {{ host }}"

# --- Linux builder (Docker/OrbStack) ---
#
# One container per target architecture, each keeping its Nix store in a Docker
# volume. x86_64 runs under Rosetta; aarch64 runs natively. See
# modules/_files/linux-builder/linux-builder for the mechanism and
# modules/linux-builder.nix for the system wiring that lets a plain `nix build`
# use these without going through these recipes.
#
# The store volume is capped (default 25 GiB) and swept before every build, so
# these are safe to run repeatedly. `linux-builder-destroy` is the reset button.
#
# These recipes never call `just` recursively. A nested `just` inside a shebang
# recipe was observed failing with "command not found: just" even though `just`
# was plainly on PATH in the same shell, so the shared steps are spelled out
# instead of factored into a recipe that others invoke.

LINUX_BUILDER := "zsh modules/_files/linux-builder/linux-builder"
NIX_CACHE_PUSH := "zsh modules/_files/nix-cache/nix-cache-push"
# No interpreter prefix on this one, unlike the two above: it is not run here at
# all — it is piped into the *target's* `sh -s` by `nixos-deploy`.
NIXOS_ACTIVATE := "modules/_files/nixos-deploy/activate"

# A clean first start seeds the volume from the image and fetches the builder's
# own openssh and coreutils — measured at 28 s. Later starts are a second or two.
# A stopped container is replaced rather than restarted, so its mounts and
# environment can never go stale; the store volume is what survives.
#
# Start the Linux builder for ARCH (x86_64 | aarch64), creating it on first use
linux-builder-up arch="x86_64":
    {{ LINUX_BUILDER }} up --arch {{ arch }}

# Remove the container. The store volume survives, so the next `up` is fast.
linux-builder-down arch="x86_64":
    {{ LINUX_BUILDER }} down --arch {{ arch }}

# Nothing is lost that cannot be rebuilt or re-substituted. Also the only way to
# pick up a new IMAGE_VERSION, since Docker seeds a volume only while it is empty.
#
# Remove the builder's container, store volume and keypair
linux-builder-destroy arch="x86_64":
    {{ LINUX_BUILDER }} destroy --arch {{ arch }}

# Container state, reported system, Nix version, and store size against the cap
linux-builder-status arch="x86_64":
    {{ LINUX_BUILDER }} status --arch {{ arch }}

# Runs automatically before every build; this is the manual form, and the place
# to try a smaller cap, e.g. `just linux-builder-gc x86_64 10`.
#
# Sweep the builder's store back under its size cap
linux-builder-gc arch="x86_64" max_gb="25":
    {{ LINUX_BUILDER }} gc --arch {{ arch }} --max-gb {{ max_gb }}

# Interactive shell inside the builder
linux-builder-shell arch="x86_64":
    {{ LINUX_BUILDER }} shell --arch {{ arch }}

# Answers "does the nix-daemon actually delegate?", which `linux-builder-status`
# cannot: that only proves the container answers ssh from THIS user. The probe
# derivation is named after the current second, because an existing output would
# be reused and prove nothing, and no cache can hold a name minted just now.
#
# Do NOT use `nix build --rebuild` for this. Check builds decline the build hook
# and must run locally, so they report `platform mismatch` even while delegation
# works — measured 2026-08-24, twice in the same minute on one derivation.
#
# Prove that Linux builds are delegated to the builder, not just substituted
linux-builder-probe arch="x86_64":
    #!/bin/zsh
    set -euo pipefail
    system="{{ arch }}-linux"
    name="delegation-probe-$(date +%Y%m%d-%H%M%S)"
    echo "→ building $name for $system — watch for 'copying path … from ssh-ng://'" >&2
    outpath=$(nix build --impure --no-link --print-out-paths --expr \
        "(builtins.getFlake \"nixpkgs\").legacyPackages.${system}.runCommand \"${name}\" {} \"{ uname -m; uname -s; } > \$out\"")
    echo "$outpath"
    # The build ran wherever the daemon put it; the output says which kernel and
    # machine that was, so a silent fallback cannot pass as success.
    cat "$outpath"

# Runs on THIS machine and reads the builder over ssh-ng, so the R2 write key
# never enters the container — the same reasoning as cache-seed-remote above.
# `--seed` is what keeps it cheap: it HEADs cache.nixos.org for every path in
# the closure and uploads only what is missing there, so R2 never pays to store
# a second copy of something the public cache already serves.
#
# An explicit /nix/store path is required, and the recipe enforces it. Given a
# symlink instead, nix-cache-push takes its remote-`readlink` branch — and that
# branch runs a bare `ssh <host> readlink`, which does NOT read NIX_SSHOPTS and
# so never learns the builder's port. It would resolve the path against THIS
# Mac's own sshd on port 22: the wrong machine, failing one step later for a
# reason that has nothing to do with the real mistake.
#
# Push the delta of a builder-produced closure to R2, signed
linux-push storepath arch="x86_64":
    #!/bin/zsh
    set -euo pipefail
    case '{{ storepath }}' in
        (/nix/store/*) ;;
        (*) echo "linux-push needs an explicit /nix/store path, got '{{ storepath }}'" >&2; exit 1 ;;
    esac
    # Store URI + NIX_SSHOPTS come from the builder script, so this works before
    # `just switch` has installed the ssh_config alias. See `push-env` there.
    eval "$({{ LINUX_BUILDER }} push-env --arch '{{ arch }}')"
    export NIX_SSHOPTS
    NIX_CACHE_S3_URL='{{ R2_S3_URL }}' {{ NIX_CACHE_PUSH }} \
      --from "$LINUX_BUILDER_STORE" --seed '{{ storepath }}'

# A bare or `.#`-prefixed attribute resolves against this checkout (mounted at
# /work); anything carrying its own flake reference is passed through.
#   just linux-build 'nixpkgs#ponysay'
#   just linux-build '.#nixosConfigurations.p-ion-berlin-xs56r6.config.system.build.toplevel'
#
# The result is pushed to R2 straight away, minus whatever cache.nixos.org
# already has. That is the point: a path built here otherwise exists in exactly
# one store in the world, inside a container meant to be disposable. Pass
# push="false" to keep a throwaway build out of the cache.
#
# Build any flake attribute on the Linux builder, push it to R2, print its path
linux-build attr arch="x86_64" push="true": _check-untracked
    #!/bin/zsh
    set -euo pipefail
    # NEVER name this `path`. In zsh `path` is the array bound to PATH, so
    # `path=$(…)` silently replaces the whole search path with the store path
    # just built — and the next command dies with "command not found: zsh"
    # several lines later, pointing nowhere near the assignment that caused it.
    # (Same trap as $cdpath/$fpath/$manpath.)
    #
    # An ARRAY, because `nix build --print-out-paths` prints one line PER OUTPUT.
    # Treating it as one string sends a multi-line blob to nix-cache-push --seed,
    # where `nix path-info --recursive` rejects it. Anything with several
    # outputsToInstall — `nixpkgs#openssl`, say — hits this.
    outpaths=("${(@f)$({{ LINUX_BUILDER }} build '{{ attr }}' --arch '{{ arch }}')}")
    if [ '{{ push }}' = true ]; then
        eval "$({{ LINUX_BUILDER }} push-env --arch '{{ arch }}')"
        export NIX_SSHOPTS
        for p in "${outpaths[@]}"; do
            NIX_CACHE_S3_URL='{{ R2_S3_URL }}' {{ NIX_CACHE_PUSH }} \
              --from "$LINUX_BUILDER_STORE" --seed "$p" >&2
        done
    fi
    # The store paths are the ONLY thing on stdout; the push logs to stderr.
    print -rl -- "${outpaths[@]}"

# Force a NixOS host's `system.build.toplevel` to EVALUATE, which is the only
# thing that makes its assertions run — and `just check` does not do it.
#
# NixOS assertions fire from baseSystemAssertWarn, i.e. only when toplevel is
# evaluated. modules/nixos-wiring.nix keys its flake checks by the host's own
# system, and `nix flake check` never realises attributes under a foreign
# system, so on an aarch64-darwin workstation every assertion in
# modules/nixos-*.nix is silently skipped. `just nixos-deploy` does evaluate
# them — inside the container, i.e. only after Docker has spun up.
#
# This is a pure evaluation: no builder, no Docker, no x86_64-linux anything.
# It asks for the .drvPath, which instantiates the derivation without realising
# it. Seconds, not minutes.
#
# Evaluate a NixOS host (runs its assertions) without building anything
nixos-eval host="p-ion-berlin-xs56r6": _check-untracked
    #!/bin/zsh
    set -euo pipefail
    drv=$(nix eval --raw ".#nixosConfigurations.$1.config.system.build.toplevel.drvPath")
    echo "$1: evaluates cleanly, assertions pass"
    echo "$drv"

# The builder architecture comes from the host's own hostPlatform, so a future
# aarch64-linux server needs no change here. Pushes to R2 like linux-build.
#
# Build a NixOS host's system closure, push it to R2, print the toplevel path
nixos-build host push="true": _check-untracked
    #!/bin/zsh
    set -euo pipefail
    system=$(nix eval --raw '.#nixosConfigurations.{{ host }}.config.nixpkgs.hostPlatform.system')
    arch="${system%%-*}"
    # `outpath`, not `path` — see the note in linux-build: zsh's $path IS $PATH.
    # A system.build.toplevel has exactly one output, so no array needed here.
    outpath=$({{ LINUX_BUILDER }} build \
      '.#nixosConfigurations.{{ host }}.config.system.build.toplevel' --arch "$arch")
    if [ '{{ push }}' = true ]; then
        eval "$({{ LINUX_BUILDER }} push-env --arch "$arch")"
        export NIX_SSHOPTS
        NIX_CACHE_S3_URL='{{ R2_S3_URL }}' {{ NIX_CACHE_PUSH }} \
          --from "$LINUX_BUILDER_STORE" --seed "$outpath" >&2
    fi
    print -r -- "$outpath"

# Build in the container, push the closure to R2, then have the target realise
# it FROM R2 and switch. The closure never crosses this machine's uplink twice.
#
# NOT agent-safe and not unattended: it activates a production system over ssh.
# The target comes from the host's own `deployTarget` (modules/nixos-wiring.nix).
#
# Build a NixOS host in Docker, publish to R2, activate it over ssh
nixos-deploy host: _check-untracked
    #!/bin/zsh
    set -euo pipefail
    system=$(nix eval --raw '.#nixosConfigurations.{{ host }}.config.nixpkgs.hostPlatform.system')
    arch="${system%%-*}"
    # Distinguish "no deployTarget" from "the flake does not evaluate" and from
    # "that host does not exist". A blanket `2>/dev/null || true` collapses all
    # three into one misleading message and hides a broken flake behind it.
    set +e
    target=$(nix eval --raw '.#deployTargets.{{ host }}' 2>/tmp/nixos-deploy-eval.$$)
    rc=$?
    set -e
    if [ $rc -ne 0 ]; then
        if grep -q "attribute '{{ host }}' missing" /tmp/nixos-deploy-eval.$$; then
            echo "{{ host }} has no deployTarget; set it in modules/hosts/{{ host }}.nix" >&2
        else
            cat /tmp/nixos-deploy-eval.$$ >&2
        fi
        rm -f /tmp/nixos-deploy-eval.$$
        exit 1
    fi
    rm -f /tmp/nixos-deploy-eval.$$

    # Prove reachability AND authentication before spending minutes building.
    # Three separate wins from one cheap round trip, and the third is why this
    # exists at all:
    #   * fail in seconds when the host is down, not after a full build+push;
    #   * fail in seconds on a wrong key, same reason;
    #   * make any biometric prompt appear NOW, while someone is still watching.
    #
    # That last one is not hypothetical. The deploy's first ssh used to come
    # after the build and the R2 upload — minutes in, when attention has moved
    # on. With the key held in 1Password behind Touch ID, the very first
    # signature raises a dialog; unanswered, ssh reports
    #     sign_and_send_pubkey: ... from agent: communication with agent failed
    # which reads like a broken agent and is nothing of the sort. Measured
    # afterwards: once authorised, signing is 0.6-1.2 s and reliable over both
    # the public address and the tunnel, so warming it up front costs nothing.
    #
    # BatchMode does NOT suppress the prompt — verified. The dialog comes from
    # the 1Password app, out of band, not from ssh.
    if ! ssh -o BatchMode=yes -o ConnectTimeout=15 "$target" true \
             2>/tmp/nixos-deploy-ssh.$$; then
        echo "cannot authenticate to $target — nothing built, nothing changed." >&2
        if grep -q 'communication with agent failed' /tmp/nixos-deploy-ssh.$$; then
            echo "" >&2
            echo "  The agent refused to SIGN, having happily offered the key." >&2
            echo "  With a 1Password-held key that almost always means a Touch ID" >&2
            echo "  prompt went unanswered. Approve it and re-run; the agent then" >&2
            echo "  caches the authorisation and later connections need no prompt." >&2
            echo "" >&2
        fi
        cat /tmp/nixos-deploy-ssh.$$ >&2
        rm -f /tmp/nixos-deploy-ssh.$$
        exit 1
    fi
    rm -f /tmp/nixos-deploy-ssh.$$

    toplevel=$({{ LINUX_BUILDER }} build \
      '.#nixosConfigurations.{{ host }}.config.system.build.toplevel' --arch "$arch")
    echo "built: $toplevel" >&2

    # Pushing is what makes the activation below cheap: the target realises the
    # closure from R2 instead of having it copied over this machine's uplink.
    eval "$({{ LINUX_BUILDER }} push-env --arch "$arch")"
    export NIX_SSHOPTS
    NIX_CACHE_S3_URL='{{ R2_S3_URL }}' {{ NIX_CACHE_PUSH }} \
      --from "$LINUX_BUILDER_STORE" --seed "$toplevel" >&2

    if [ "$arch" = x86_64 ]; then
        # Say it out loud. Rosetta has at least one demonstrated silent
        # miscompile (golang/go#79205, AVX2 chacha20poly1305), and an emulated
        # build lands at the SAME store path as a native one and is signed with
        # the same key. To audit: `nix build --rebuild <path>` on the target,
        # which reports differing output for identical input.
        echo "NOTE: built under Rosetta emulation, not natively." >&2
    fi

    # --- activate, with an armed rollback --------------------------------
    # deploy-rs' magicRollback, minus deploy-rs. A timer is armed on the target
    # BEFORE the switch; liveness is then proven by disarming it over a SECOND,
    # fresh ssh connection. If the switch cuts the network — a bad firewall
    # rule, an sshd that does not come back, a broken interface — nobody
    # disarms it and the target restores the previous generation by itself.
    # This is the whole reason a config change to this host is not a coin flip:
    # its only other fallback is the Cloud Panel's KVM console via GRUB.
    #
    # Two limits, stated rather than discovered later:
    #   * transient units do NOT survive a reboot, so a config that only breaks
    #     at boot is not covered — that is what the GRUB generation list is for;
    #   * if THIS machine dies between switch and disarm, the target rolls back
    #     although nothing was wrong. Same trade-off deploy-rs makes.
    rollback_delay=${NIXOS_DEPLOY_ROLLBACK_DELAY:-300}
    echo "activating on $target (rollback armed: ${rollback_delay}s) ..." >&2

    # The activation script lives in its own file and is piped to the target's
    # `sh -s` — see the header of {{ NIXOS_ACTIVATE }} for why sh and not zsh,
    # and why piping rather than an ssh command string. It is a FILE and not a
    # heredoc for a duller reason: just strips the *common* leading whitespace
    # from a shebang recipe, so a heredoc terminator at column 0 would flatten
    # the indentation of the entire recipe around it.
    if ! ssh -o BatchMode=yes "$target" sh -s -- "$toplevel" "$rollback_delay" \
           < {{ NIXOS_ACTIVATE }}; then
        echo "activation FAILED — leaving the rollback armed on purpose." >&2
        echo "  $target restores its previous generation within ${rollback_delay}s." >&2
        exit 1
    fi

    # The disarm is a NEW connection, and that is the entire point: it is the
    # liveness proof, not a formality. Failing here must not be "fixed" by
    # retrying with the timer stopped.
    if ssh -o BatchMode=yes -o ConnectTimeout=15 "$target" \
         systemctl stop deploy-rollback.timer; then
        echo "confirmed reachable; rollback disarmed" >&2
    else
        echo "WARNING: $target did not answer after the switch." >&2
        echo "  Do nothing — that is the correct action. The armed timer will" >&2
        echo "  restore the previous generation within ${rollback_delay}s." >&2
        exit 1
    fi
