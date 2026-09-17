#!/usr/bin/env python3
"""Maintain Nix-owned MCP entries and a table of owned leaves in writable
config.toml.

The Nix activation supplies the interpreter and tomli-w dependency. The state
file records previous values, not just names: a user edit to an mcp_servers
entry causes a conflict rather than being overwritten. Each leaf in LEAVES
(the TUI status line, the default model, its two reasoning-effort fields, and
the reasoning_effort_override feature flag) is authoritative instead: set
every activation while managed; on disable,
removed only if the file still holds the value this script last wrote, so an
interactive change (Codex's own /model or /statusline) made after that is left
alone rather than reported as a conflict. A pending snapshot makes a two-file
update recoverable after interruption. Neither file contains credentials
supplied by this module; MCP authentication is expressed through
environment-variable names.
"""

import argparse
import json
import os
from pathlib import Path
import re
import sys
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
    have --state and must rely on their ownership journal instead. This is
    mcp_servers-only: a generation this old predates every leaf in LEAVES, so
    there is no previous leaf ownership to recover -- state.get("owned_<key>")
    simply reads as None, exactly like a freshly managed machine.
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


# Leaves the activation owns outright: authoritative while managed, and on
# disable removed only when the file still holds the value last written --
# unlike mcp_servers, where a differing value is a conflict, not silently
# adopted. Each tuple is:
#   journal key suffix (-> owned_<key> / pending_<key> in the state file;
#     its own namespace, separate from "owned"/"pending", which belong to
#     mcp_servers),
#   path in the TOML tree (depth 1 or 2 -- set_leaf prunes only the direct
#     parent and must not be applied at depth 3),
#   a predicate for a VALID value (not a type token: "list of str" needs a
#     lambda anyway, and a bare isinstance(v, list) would admit ["a", 3]).
# "status_line" reproduces the field name owned_status_line/pending_status_line
# from before this table existed, so a journal from an older generation
# without owned_model/... needs no migration: .get() simply returns None for
# the missing fields, which here means "unmanaged".
LEAVES = (
    ("status_line", ("tui", "status_line"),
     lambda v: isinstance(v, list) and all(isinstance(i, str) for i in v)),
    ("model", ("model",), lambda v: isinstance(v, str)),
    ("reasoning_effort", ("model_reasoning_effort",), lambda v: isinstance(v, str)),
    ("plan_reasoning_effort", ("plan_mode_reasoning_effort",), lambda v: isinstance(v, str)),
    # isinstance(v, bool) is exact in the direction that matters here: it
    # rejects a JSON 1/0 in the journal, even though the reverse
    # (isinstance(True, int)) would be true. Do NOT relax it to (bool, int).
    ("reasoning_effort_override", ("features", "reasoning_effort_override"),
     lambda v: isinstance(v, bool)),
)
# Only "model" gets a stderr line when it silently replaces a value it does
# not already own: Codex's own /model picker writes that key on every
# interactive choice, and a plain rebuild reverting it with no output at all
# would otherwise go unnoticed for hours. The other leaves keep the existing,
# fully silent behavior.
NOTIFY_ON_OVERWRITE = {"model"}


def get_leaf(mapping, path):
    """Return the value at `path`, or None. Raise ValueError if an
    INTERMEDIATE node exists but is not a table (replaces the previous
    one-off "tui is not a table" check). Never validates the leaf value's own
    type -- that is the caller's job, and deliberately only for `managed` and
    the journal, never for `config` (see the validation step in merge())."""
    node = mapping
    for key in path[:-1]:
        node = node.get(key, {})
        if not isinstance(node, dict):
            raise ValueError(f"{key} is not a table")
    return node.get(path[-1])


def set_leaf(result, path, value):
    """Set or remove (value=None) the leaf in `result`, copy-on-write at
    every intermediate level.

    Copy-on-write is not a style choice here: reconcile()'s `result =
    dict(config)` is a SHALLOW copy, so e.g. result["tui"] is the very same
    object as config["tui"] until first written. A naive `result[parent][leaf]
    = ...` or `setdefault` walk would mutate `config` itself, and the
    `result != config` comparison that decides whether the target file is
    rewritten at all would then wrongly read False -- silently discarding a
    user's edit instead of preserving it. Every level is therefore copied
    with dict(...) before it is changed, and only then written back.

    Depth 1 (model, both reasoning fields) targets the root directly and
    never removes it. Depth 2 ([tui].status_line,
    [features].reasoning_effort_override) prunes the parent table once it
    becomes empty -- and only then: a real ~/.codex/config.toml keeps its own
    keys in [features] (memories, js_repl, ...), which must survive a disable.
    """
    node = result
    for key in path[:-1]:
        child = node.get(key, {})
        if not isinstance(child, dict):
            raise ValueError(f"{key} is not a table")
        copy = dict(child)                       # copy, never alias config
        node[key] = copy                         # write BEFORE `node` moves on
        node = copy
    if value is None:
        node.pop(path[-1], None)
    else:
        node[path[-1]] = value
    if len(path) > 1 and not node:               # only ever prune a real parent
        result.pop(path[0], None)


def merge(managed_path, target_path, state_path, previous_activation=None):
    target_path, state_path = Path(target_path), Path(state_path)
    managed = load_toml(managed_path)
    desired = managed.get("mcp_servers", {})
    state = {}
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

    # Validate only what Nix proposes and what the journal records for each
    # leaf -- never the on-disk config. A hand-edited `model = 42` must not
    # fail the whole `darwin-rebuild switch`; see the comment below.
    desired_leaf = {}
    for key, path, valid in LEAVES:
        desired_leaf[key] = get_leaf(managed, path)
        for value in (desired_leaf[key], state.get(f"owned_{key}"), state.get(f"pending_{key}")):
            if value is not None and not valid(value):
                raise ValueError(f"invalid {key} settings or ownership state")

    # An unused integration must not create files in an external agent's home.
    if (not desired and not owned and not pending and not state_path.exists()
            and all(value is None for value in desired_leaf.values())):
        return

    config = load_toml(target_path)
    result = reconcile(config, desired, owned, pending)

    # Leaf values are read from `config` once, before any mutation of
    # `result` -- the ownership decision must reflect the state from BEFORE
    # this activation, and `result` is what this loop is about to change.
    current = {key: get_leaf(config, path) for key, path, _ in LEAVES}
    current_owned = {}
    for key, path, _ in LEAVES:
        owned_value = state.get(f"owned_{key}")
        pending_value = state.get(f"pending_{key}")
        matches_owned = current[key] is not None and current[key] in (owned_value, pending_value)
        if desired_leaf[key] is not None:
            if (key in NOTIFY_ON_OVERWRITE and current[key] is not None
                    and current[key] != desired_leaf[key] and not matches_owned):
                # No config content in the message (see the module docstring
                # and the error handling in main()): a model name is not a
                # secret, but that restraint stays the rule elsewhere -- this
                # is a narrow, deliberate exception for exactly this leaf.
                print(f"codex config merge: {key} {current[key]!r} -> {desired_leaf[key]!r}",
                      file=sys.stderr)
            set_leaf(result, path, desired_leaf[key])         # authoritative: always overwrite
        elif matches_owned:
            set_leaf(result, path, None)                      # remove only if it's still ours
        current_owned[key] = current[key] if matches_owned else None

    # Journal before replacing config; a retry accepts either old or new
    # values. owned_<key> here is the PREVIOUS ownership (recovery base if
    # this run is interrupted before the config write completes); the final
    # write below records the NEW ownership instead.
    journal = {"version": 1, "owned": owned, "pending": desired}
    for key, _, _ in LEAVES:
        journal[f"owned_{key}"] = current_owned[key]
        journal[f"pending_{key}"] = desired_leaf[key]
    # Retain a previous interrupted update until this transaction completes.
    mcp_current = config.get("mcp_servers", {})
    journal["owned"] = {
        name: mcp_current[name] for name in owned.keys() | pending.keys() if name in mcp_current
    }
    atomic_write(state_path, json.dumps(journal).encode())
    if result != config or target_path.is_symlink():
        mode = target_path.stat().st_mode & 0o777 if target_path.exists() else 0o600
        # Store symlinks must become writable regular files.
        if target_path.is_symlink():
            mode = 0o600
        atomic_write(target_path, tomli_w.dumps(result).encode(), mode)
    # After a successful write: "owned" now means what we just set. Leaves
    # out every pending_<key> deliberately -- a stray one from a long-finished
    # transaction must never authorize a later disable to retract a value it
    # was never actually responsible for.
    atomic_write(state_path, json.dumps({
        "version": 1, "owned": desired,
        **{f"owned_{key}": desired_leaf[key] for key, _, _ in LEAVES},
    }).encode())


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
            parser.exit(1, "codex config merge: invalid TOML; no changes written\n")
        parser.exit(1, f"codex config merge: {error}\n")


if __name__ == "__main__":
    main()
