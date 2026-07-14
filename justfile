# Nix-darwin configuration tasks
# Safe for LLM agents — no sudo, no destructive operations

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
    #!/usr/bin/env bash
    set -euo pipefail
    untracked=$(git status --porcelain | grep -E '^\?\? (modules|hosts)/' || true)
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
    time darwin-rebuild build --flake . --keep-going --keep-failed -L | ts

# Build a specific host configuration
build-host host: _check-untracked
    time nix build '.#darwinConfigurations.{{ host }}.system' --keep-going --keep-failed | ts

# Run flake checks
check: _check-untracked
    nix flake check

# Format all Nix files
fmt:
    nix run nixpkgs#nixpkgs-fmt -- $(find . -name '*.nix' -not -path './_*')

# Format and check — returns non-zero if files were changed
fmt-check:
    nix run nixpkgs#nixpkgs-fmt -- --check $(find . -name '*.nix' -not -path './_*')

# Update all flake inputs
update:
    nix flake update

# Update a single flake input
update-input input:
    nix flake lock --update-input {{ input }}

# Show what would change between current system and new build
diff: build
    nix store diff-closures /run/current-system ./result

# Build and verify no package delta (useful after refactoring)
verify-no-diff: build
    #!/usr/bin/env bash
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

# Decrypt and view the Boundary reference doc (hosts/DKL6GDJ7X1/BOUNDARY.md.gpg)
view-boundary-doc:
    gpg --decrypt hosts/DKL6GDJ7X1/BOUNDARY.md.gpg | less -R

# Edit the Boundary reference doc: decrypt -> $EDITOR -> re-encrypt to all three recipients
edit-boundary-doc:
    #!/usr/bin/env bash
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

# One-time per machine: install the sops age identity so the CLI decrypts secrets automatically
sops-age-setup:
    #!/usr/bin/env bash
    set -euo pipefail
    # Derived from the workstation SSH key (non-default name, so sops can't find
    # it; ~/.ssh/id_ed25519 is a different key). Written to sops' per-OS default
    # key location (macOS: Application Support; else XDG) so no env is needed.
    case "$(uname)" in
      Darwin) dir="$HOME/Library/Application Support/sops/age" ;;
      *)      dir="${XDG_CONFIG_HOME:-$HOME/.config}/sops/age" ;;
    esac
    mkdir -p "$dir"
    nix run nixpkgs#ssh-to-age -- -i "$HOME/.ssh/id_ed25519_sops_nopw" -private-key > "$dir/keys.txt"
    chmod 600 "$dir/keys.txt"
    echo "Wrote $dir/keys.txt — sops can now decrypt without extra env."

# Run any pulumi command in infra/ with the Pulumi Cloud + Cloudflare tokens from SOPS (needs sops-age-setup once)
pulumi *args:
    #!/usr/bin/env bash
    set -euo pipefail
    PULUMI_ACCESS_TOKEN="$(sops -d --extract '["pulumi_access_token"]' secrets/infra.enc.yaml)"
    export PULUMI_ACCESS_TOKEN
    # The default cloudflare provider (and CLI `pulumi import`) reads this env var.
    CLOUDFLARE_API_TOKEN="$(sops -d --extract '["cloudflare_api_token"]' secrets/infra.enc.yaml)"
    export CLOUDFLARE_API_TOKEN
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
    cd infra && time pnpm install | ts

# --- Nix binary cache (Cloudflare R2) ---

# Endpoint of the S3 push target (public pull URL is the custom domain).
R2_S3_URL := "s3://nix-cache?endpoint=81e63dbf073ca45ebf67c430beac09a4.r2.cloudflarestorage.com&region=auto"

# Seed R2 with the current system's delta (paths not already on cache.nixos.org)
cache-seed:
    NIX_CACHE_S3_URL='{{ R2_S3_URL }}' bash modules/_files/nix-cache/nix-cache-push --seed

# Push specific paths (repair/ad hoc), e.g. `just cache-push /run/current-system`
cache-push *paths:
    NIX_CACHE_S3_URL='{{ R2_S3_URL }}' bash modules/_files/nix-cache/nix-cache-push "$@"

# Bootstrap a fresh machine: pre-fetch the R2-cached delta (the paths NOT on
# cache.nixos.org) into the store BEFORE the first switch, so that first —
# otherwise most expensive — build downloads them instead of compiling from
# source. Needs sudo: on a fresh box the login user isn't a trusted-user yet
# (that only lands at the first activation) and nix.custom.conf doesn't exist,
# so only a root (always-trusted) invocation with explicit flags makes the
# daemon honor R2. Then apply the printed switch. Example: `just bootstrap DKL6GDJ7X1`
bootstrap host:
    #!/usr/bin/env bash
    set -euo pipefail
    sudo nix build --no-link \
      --extra-substituters 'https://nix-cache.pub.schwetschke.dev' \
      --extra-trusted-public-keys 'nix-cache.pub.schwetschke.dev-1:R3UAHtpY90nzsAtEm3LDaWsEAHYQK6YG+i8mYxTgL10=' \
      '.#darwinConfigurations.{{ host }}.system'
    echo
    echo "R2 delta is in the local store. Now apply it:"
    echo "  sudo darwin-rebuild switch --flake ."
