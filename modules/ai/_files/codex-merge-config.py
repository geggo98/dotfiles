#!/usr/bin/env python3
"""Merge nix-managed settings into Codex's writable config.toml.

Usage: codex-merge-config.py <managed.toml> <target-config.toml>

Codex persists directory trust ([projects."<path>"]) and TUI settings
into $CODEX_HOME/config.toml, so the file must stay a regular writable
file — a home-manager symlink into the nix store makes those writes
fail (config/batchWrite, code -32603). Instead, this script runs on
every home-manager activation: top-level keys from the managed file
replace their counterparts in the target wholesale (mcp_servers gets
fresh store paths, removed servers disappear), everything Codex wrote
itself is preserved.
"""

import os
import sys
import tempfile
import tomllib

import tomli_w


def load(path):
    try:
        with open(path, "rb") as f:
            return tomllib.load(f)
    except FileNotFoundError:
        return {}


def main():
    managed_path, target_path = sys.argv[1], sys.argv[2]

    config = load(target_path)
    config.update(load(managed_path))

    # Replace a leftover store symlink with a regular file.
    if os.path.islink(target_path):
        os.unlink(target_path)

    target_dir = os.path.dirname(target_path) or "."
    os.makedirs(target_dir, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=target_dir, suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as f:
            tomli_w.dump(config, f)
        os.chmod(tmp, 0o644)
        os.replace(tmp, target_path)
    except BaseException:
        os.unlink(tmp)
        raise


if __name__ == "__main__":
    main()
