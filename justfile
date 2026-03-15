# Nix-darwin configuration tasks
# Safe for LLM agents — no sudo, no destructive operations

# Default: list available tasks
default:
    @just --list

# Build the current host configuration (without applying)
build:
    darwin-rebuild build --flake .

# Build a specific host configuration
build-host host:
    nix build '.#darwinConfigurations.{{host}}.system'

# Run flake checks
check:
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
eval:
    nix eval '.#darwinConfigurations' --apply 'x: builtins.attrNames x'

# Show derivation of current host build
show-derivation:
    nix derivation show '.#darwinConfigurations.FCX19GT9XR.system' | nix run nixpkgs#jq -- .
