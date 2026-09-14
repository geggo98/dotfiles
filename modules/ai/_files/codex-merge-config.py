#!/usr/bin/env python3
"""Maintain only Nix-owned MCP entries in Codex's writable config.toml.

The Nix activation supplies the interpreter and tomli-w dependency. The state
file records previous values, not just names: a user edit causes a conflict
rather than being overwritten. A pending snapshot makes a two-file update
recoverable after interruption. Neither file contains credentials supplied by
this module; MCP authentication is expressed through environment-variable names.
"""

import argparse
import json
import os
from pathlib import Path
import re
import tempfile
import tomllib

import tomli_w


def load_toml(path):
    try:
        with open(path, "rb") as stream:
            return tomllib.load(stream)
    except FileNotFoundError:
        return {}


def atomic_write(path, data, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(tmp, mode)
        # Also replaces a legacy symlink without unlinking it first.
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def legacy_owned(previous_activation):
    """Read the old generated MCP table, never the user's current config.

    Match the original two-argument activation command only. New activations
    have --state and must rely on their ownership journal instead.
    """
    if not previous_activation:
        return {}
    path = Path(previous_activation)
    if not str(path).startswith("/nix/store/") or not path.is_file():
        return {}
    # Input: run /nix/store/.../bin/python3 /nix/store/...-codex-merge-config.py \
    #          /nix/store/...-codex-managed-settings "$HOME/.codex/config.toml"
    match = re.search(
        r'^run /nix/store/[^\s]+/bin/python3 '
        r'/nix/store/[^\s]+-codex-merge-config\.py \\\n'
        r'\s+(?P<settings>/nix/store/[^\s]+-codex-managed-settings) '
        r'"\$HOME/\.codex/config\.toml"[ \t]*$',
        path.read_text(),
        re.MULTILINE,
    )
    if not match:
        return {}
    return load_toml(match.group("settings")).get("mcp_servers", {})


def reconcile(config, desired, owned, pending=None):
    """Return a new config or raise before any write on a name conflict."""
    current = config.get("mcp_servers", {})
    if not isinstance(current, dict):
        raise ValueError("mcp_servers is not a table")
    pending = pending or {}
    managed_names = owned.keys() | pending.keys()
    for name in managed_names | desired.keys():
        if name not in current:
            continue
        allowed = [table[name] for table in (owned, pending) if name in table]
        if not allowed and name in desired:
            # A pre-existing identical definition needs no destructive adoption.
            allowed = [desired[name]]
        if current[name] not in allowed:
            raise ValueError(
                f"MCP entry {name!r} conflicts with Nix ownership; "
                "rename the personal entry or restore the managed definition."
            )
    servers = {name: value for name, value in current.items() if name not in managed_names}
    servers.update(desired)
    result = dict(config)
    if servers:
        result["mcp_servers"] = servers
    else:
        result.pop("mcp_servers", None)
    return result


def merge(managed_path, target_path, state_path, previous_activation=None):
    target_path, state_path = Path(target_path), Path(state_path)
    desired = load_toml(managed_path).get("mcp_servers", {})
    try:
        state = json.loads(state_path.read_text())
        if state.get("version") != 1 or not isinstance(state.get("owned"), dict):
            raise ValueError("unsupported MCP ownership state")
        owned = state["owned"]
        pending = state.get("pending", {})
        if not isinstance(pending, dict):
            raise ValueError("invalid pending MCP ownership state")
    except FileNotFoundError:
        owned = legacy_owned(previous_activation)
        pending = {}
    # An unused integration must not create files in an external agent's home.
    if not desired and not owned and not pending and not state_path.exists():
        return
    config = load_toml(target_path)
    result = reconcile(config, desired, owned, pending)
    # Journal before replacing config; a retry accepts either old or new values.
    journal = {"version": 1, "owned": owned, "pending": desired}
    # Retain a previous interrupted update until this transaction completes.
    current = config.get("mcp_servers", {})
    journal["owned"] = {
        name: current[name] for name in owned.keys() | pending.keys() if name in current
    }
    atomic_write(state_path, json.dumps(journal).encode())
    if result != config or target_path.is_symlink():
        mode = target_path.stat().st_mode & 0o777 if target_path.exists() else 0o600
        # Store symlinks must become writable regular files.
        if target_path.is_symlink():
            mode = 0o600
        atomic_write(target_path, tomli_w.dumps(result).encode(), mode)
    atomic_write(state_path, json.dumps({"version": 1, "owned": desired}).encode())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("managed")
    parser.add_argument("target")
    parser.add_argument("--state", required=True)
    parser.add_argument("--previous-activation")
    args = parser.parse_args()
    try:
        merge(args.managed, args.target, args.state, args.previous_activation)
    except (ValueError, OSError) as error:
        # Do not print TOML contents: the personal config may contain secrets.
        if isinstance(error, tomllib.TOMLDecodeError):
            parser.exit(1, "codex MCP merge: invalid TOML; no changes written\n")
        parser.exit(1, f"codex MCP merge: {error}\n")


if __name__ == "__main__":
    main()
