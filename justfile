# Nix-darwin configuration tasks
# Safe for LLM agents — no sudo, no destructive operations

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

# Build the current host configuration (without applying)
build: _check-untracked
    darwin-rebuild build --flake .

# Build a specific host configuration
build-host host: _check-untracked
    nix build '.#darwinConfigurations.{{host}}.system'

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
    nix flake lock --update-input {{input}}

# Show what would change between current system and new build
diff: build
    nix store diff-closures /run/current-system result

# Build and verify no package delta (useful after refactoring)
verify-no-diff: build
    #!/usr/bin/env bash
    set -euo pipefail
    diff_output=$(nix store diff-closures /run/current-system result 2>&1)
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
