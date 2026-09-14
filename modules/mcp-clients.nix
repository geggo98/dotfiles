{ config, ... }:
let
  aiOptions = config.flake.modules.homeManager.ai-options;
in
{
  flake.modules.homeManager.mcp-servers = { config, pkgs, lib, ... }:
    let
      cfg = config.my.ai.mcp;
      mcpServers = cfg.servers;
      loadSecretsLib = builtins.readFile ./_files/shell/load-secrets.sh;
      mcpCmd = _: pkg: lib.getExe pkg;

      # Claude runs this at CONNECTION time and parses stdout as a JSON object
      # of headers.
      #
      # It reads the sops FILE rather than an env var, and that is load-bearing
      # rather than stylistic: claude-code runs headersHelpers from plugin
      # sources with scrubCredentialEnv, so an inherited $TRAVILY_API_KEY would
      # arrive EMPTY and we would ship an empty Bearer token — a 401 with no
      # visible cause. Do not "simplify" this to read the variable.
      #
      # jq, not printf: a key containing " or \\ would otherwise produce invalid
      # JSON. require_secrets exiting non-zero is deliberate — claude then fails
      # the connection loudly instead of connecting anonymously.
      mkHeadersHelper = name: auth: (pkgs.writeShellApplication {
        name = "+mcp-headers-${name}";
        runtimeInputs = [ pkgs.jq ];
        text = ''
          ${loadSecretsLib}
          load_from_secret ${auth.var} ${auth.secret}
          require_secrets ${auth.var}
          jq -n --arg v "''${${auth.var}}" '{ Authorization: ("Bearer " + $v) }'
        '';
      });

      # Deliberately NOT in home.packages: these print credentials.
      headersHelpers = lib.mapAttrs (name: s: mkHeadersHelper name s.remote.auth)
        (lib.filterAttrs (_: s: s.remote != null && s.remote.auth != null) mcpServers);

      headersHelperCmd = name: "${headersHelpers.${name}}/bin/+mcp-headers-${name}";

      # One transport adapter per client, shared by native integration and
      # portable exports. Adding a client also requires declaring its name in
      # ai-options.nix and wiring its native sink in agent-integration.nix.
      #
      #   remote     may this agent use the remote transport at all? Flipping
      #              one of these to true is the whole migration for that agent.
      #   authKinds  which auth kinds it can carry. A server whose auth kind is
      #              not listed falls back to stdio for that agent rather than
      #              silently connecting unauthenticated.
      #
      # Transport support, each verified against the INSTALLED binary on
      # 2026-09-10, not taken from documentation:
      #   claude-code 2.1.258  type/url/headers/headersHelper — bundle grep,
      #                        counted against control tokens first so a
      #                        vacuous zero could not pass as an answer.
      #   codex 0.147.0        url + bearer_token_env_var — `codex mcp add
      #                        --url … --bearer-token-env-var …` into a
      #                        throwaway CODEX_HOME, then read config.toml.
      #   opencode 1.18.18     type="remote" + url + headers — but whether
      #                        {file:…} substitutes INSIDE a nested header
      #                        string is UNVERIFIED, so it stays on stdio.
      authKind = r: if r.auth == null then "none" else r.auth.kind;

      # Built from xdg.configHome, NOT from config.sops.secrets.<n>.path.
      # Dereferencing sops.secrets is an EVAL error on a host that does not
      # declare the secret (AGENTS.md, "Watch for Nix-side references"), and
      # this module reaches both workstations.
      secretFile = n: "${config.xdg.configHome}/sops-nix/secrets/${n}";

      agents = {
        claude = {
          # Remote since 2026-09-10. This is the change that removes the MCP
          # processes: claude-code connects http servers LAZILY, on first tool
          # use, while stdio servers are started at session start. Measured
          # before: 13 processes / 491 MiB per session, none of them computing
          # (0,5-1,5 s CPU over 53 min) — `npx -y` keeps an `npm exec` node VM
          # alive next to every server, so each one cost two processes.
          #
          # Do NOT set alwaysLoad to make failures surface at startup again: it
          # also opts the server out of tool-schema deferral, putting every tool
          # schema into each turn's context. `just mcp-check` is the startup
          # check instead.
          remote = true;
          exclude = config.my.ai.mcp.clients.claude.exclude;
          authKinds = [ "none" "bearer" ];
          mkRemote = name: r: { type = "http"; url = r.url; }
            // lib.optionalAttrs (r.auth != null) { headersHelper = headersHelperCmd name; };
          mkStdio = name: pkg: { type = "stdio"; command = mcpCmd name pkg; args = [ ]; };
        };

        opencode = {
          # false until the {file:…}-inside-a-header question above is settled.
          # mkRemote is already written and already correct; this word is the
          # whole switch.
          remote = false;
          exclude = config.my.ai.mcp.clients.opencode.exclude;
          authKinds = [ "none" "bearer" ];
          mkRemote = _: r: { type = "remote"; url = r.url; enabled = true; }
            // lib.optionalAttrs (r.auth != null) {
            headers.Authorization = "Bearer {file:${secretFile r.auth.secret}}";
          };
          mkStdio = name: pkg: { type = "local"; command = [ (mcpCmd name pkg) ]; enabled = true; };
        };

        codex = {
          # Remote since 2026-09-10. Codex carries the credential as
          # `bearer_token_env_var`, i.e. the NAME of an env var it resolves
          # itself — no literal in ~/.codex/config.toml, which the merge script
          # keeps writable and which needs no rewrite when sops rotates a key.
          # The variables are loaded by the +agent-codex wrapper.
          remote = true;
          exclude = config.my.ai.mcp.clients.codex.exclude;
          authKinds = [ "none" "bearer" ];
          mkRemote = _: r: { url = r.url; }
            // lib.optionalAttrs (r.auth != null) { bearer_token_env_var = r.auth.var; };
          mkStdio = name: pkg: { command = mcpCmd name pkg; args = [ ]; };
        };

        antigravity = {
          # Remote only for servers WITHOUT a credential. Measured 2026-09-11
          # against agy 1.1.22 in a scratch HOME — `agy mcp add --header
          # "Authorization: Bearer TOKEN" api https://…` and `agy mcp add
          # --env FOO=bar fs -- npx …` — and read back from the file it wrote:
          # a remote server is `serverUrl` + `headers` with the token as a
          # LITERAL, a stdio one is `command`/`args`/`env`, both carry
          # `disabled`. No headers helper, no env-var NAME, no `''${VAR}`
          # interpolation anywhere in the binary. A literal would land in
          # /nix/store, so "bearer" is absent from authKinds and renderFor
          # routes context7 and travily through their stdio wrappers, which
          # read the sops file per start — the opencode shape. The price is
          # one node process per server and session; the alternative, a file
          # rendered at activation from the sops files, is a second plaintext
          # copy that goes stale on rotation.
          #
          # `url`/`httpUrl` are documented as unsupported legacy keys; only
          # `serverUrl` is read.
          remote = true;
          exclude = config.my.ai.mcp.clients.antigravity.exclude;
          authKinds = [ "none" ];
          mkRemote = _: r: { serverUrl = r.url; };
          mkStdio = name: pkg: { command = mcpCmd name pkg; args = [ ]; };
        };
      };

      renderFor = agent:
        let
          visible = builtins.removeAttrs mcpServers agent.exclude;
          useRemote = s: agent.remote && s.remote != null
            && builtins.elem (authKind s.remote) agent.authKinds;
        in
        lib.mapAttrs
          (name: s: if useRemote s then agent.mkRemote name s.remote else agent.mkStdio name s.stdio)
          visible;

      rendered = lib.mapAttrs (_: renderFor) agents;
      # Exports cannot rely on an installed +agent wrapper to load credentials.
      portable = lib.mapAttrs
        (_: agent: renderFor (agent // {
          remote = true;
          authKinds = [ "none" ];
        }))
        agents;
      exportFor = name:
        if name == "codex" then
          (pkgs.formats.toml { }).generate "codex-mcp-export.toml" { mcp_servers = portable.${name}; }
        else
          (pkgs.formats.json { }).generate "${name}-mcp-export.json"
            (if name == "opencode" then { mcp = portable.${name}; }
            else { mcpServers = portable.${name}; });
    in
    {
      imports = [ aiOptions ];
      config = lib.mkIf cfg.enable {
        my.ai.mcp.rendered = rendered;
        xdg.configFile = lib.genAttrs
          (map (name: "ai/mcp/${name}.${if name == "codex" then "toml" else "json"}") cfg.exports)
          (path:
            let name = lib.removeSuffix ".json" (lib.removeSuffix ".toml" (baseNameOf path));
            in { source = exportFor name; });
      };
    };
}
