"""Validate standalone MCP exports and absence of hidden agent dependencies."""
import json
from pathlib import Path
import re
import sys
import tomllib

claude, codex, opencode, agy, wt, mcp_closure, off_closure = map(Path, sys.argv[1:])
claude = json.loads(claude.read_text())["mcpServers"]
codex = tomllib.loads(codex.read_text())["mcp_servers"]
opencode = json.loads(opencode.read_text())["mcp"]
agy = json.loads(agy.read_text())["mcpServers"]
for client in (claude, codex, opencode, agy):
    for name in ("context7", "travily"):
        assert "command" in client[name], client[name]
        assert "bearer_token_env_var" not in client[name]
        command = client[name]["command"]
        if isinstance(command, list):
            command = command[0]
        assert command.startswith("/nix/store/") and command.endswith(f"/bin/+mcp-{name}")
        assert Path(command).is_file()
    assert "atlassian" not in client  # no host credentials in isolated configuration
assert "url" in claude["javadocs"]
assert "url" in codex["javadocs"]
assert "url" in opencode["javadocs"]
assert "serverUrl" in agy["javadocs"]
assert "devenv" not in claude and "devenv" not in agy
assert "devenv" in codex and "devenv" in opencode
assert "generation" not in tomllib.loads(wt.read_text()).get("commit", {})
for path in (mcp_closure, off_closure):
    paths = path.read_text().splitlines()
    assert paths, "empty closure cannot prove isolation"
    # matches: /nix/store/<hash>-claude-code-2.x or ...-+agent-codex
    forbidden = re.compile(r"-(?:claude-code|codex|opencode|gemini-cli|antigravity-cli|claude-agent-acp|codex-acp)(?:-\d|$)|-\+agent-")
    hits = [p for p in paths if forbidden.search(p)]
    assert not hits, hits
print("Portable exports, client exclusions, Worktrunk gating and transitive closures verified.")
