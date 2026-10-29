{ ... }:
{
  # Shared declarations only: importing this aspect activates no software.
  flake.modules.homeManager.ai-options = { lib, ... }:
    let
      inherit (lib) mkOption mkEnableOption types;
      agentNames = [ "claude" "codex" "opencode" "gemini" "antigravity" ];
      clientNames = [ "claude" "codex" "opencode" "antigravity" ];
    in
    {
      # Deferred aspect imports are anonymous wrappers; give the shared schema
      # a stable identity so importing several consumers declares it only once.
      key = "nix-darwin-ai-options";
      options.my.ai = {
        agents = {
          enable = mkEnableOption "Nix-managed agent packages, wrappers and settings";
        } // lib.genAttrs agentNames (name: {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = "Manage this agent when my.ai.agents.enable is set.";
          };
        } // lib.optionalAttrs (name == "codex") {
          environmentScript = mkOption {
            type = types.lines;
            default = "";
            internal = true;
            description = "Runtime environment contributed by agent integrations.";
          };
          model = mkOption {
            type = types.nullOr types.str;
            default = "gpt-6.1-sol";
            description = "Default model merged into Codex's writable config.toml; null leaves the key unmanaged and gives back a previously owned value.";
          };
          reasoningEffort = mkOption {
            type = types.nullOr types.str;
            default = "medium";
            description = "model_reasoning_effort for Codex's default (execute) mode; null leaves it unmanaged.";
          };
          # CLI only: Codex Desktop enters Plan mode without applying this and
          # keeps model_reasoning_effort instead. Open upstream bug:
          # https://github.com/openai/codex/issues/18712
          planReasoningEffort = mkOption {
            type = types.nullOr types.str;
            default = "xhigh";
            description = "plan_mode_reasoning_effort for Codex's Plan mode (Shift+Tab); null leaves it unmanaged.";
          };
          # Upstream feature flag `[features] reasoning_effort_override` (PR #43110,
          # first shipped in 0.154.0). EXPERIMENTAL: still Stage::UnderDevelopment
          # and default-off upstream.
          #
          # With it on, codex appends a `configuration_update` history item
          # whenever the resolved reasoning effort changes mid-session -- which
          # entering Plan mode always does here, because planReasoningEffort
          # ("xhigh") differs from reasoningEffort ("medium"). The item is meant to
          # leave the cached prompt prefix intact.
          #
          # It was OFF while openai/codex#44751 was fresh: 0.154.0..0.156.x sent
          # the item to gpt-5.6-luna/-terra/-sol, which answered HTTP 400 on every
          # following turn. The issue is still open, but codex now gates the send
          # per model on `supports_reasoning_effort_updates` in the bundled
          # catalog (codex-rs/core/src/client.rs). Measured 2026-10-05: in 0.160.0
          # gpt-6-astra and gpt-6.1-sol set it; gpt-6-sol and gpt-6-luna do not and
          # never receive the item. In 0.156.1 no model set it, so the flag was
          # inert. Hence this is only worth turning on together with a model that
          # sets the gate -- the default `model` above is gpt-6.1-sol for that
          # reason. "Works across the whole GPT-6 suite" is not what the catalog
          # says.
          # https://github.com/openai/codex/issues/44751
          reasoningEffortOverride = mkOption {
            type = types.nullOr types.bool;
            default = true;
            description = "Upstream [features] reasoning_effort_override in Codex's writable config.toml; null leaves the key unmanaged and gives back a previously owned value.";
          };
          # Since 0.157.0 every interactive `codex` start launches a persistent
          # `codex app-server --managed-daemon`, copies the ~374 MB platform
          # package into ~/.codex/packages/app-server-daemon/ and starts a
          # detached hourly self-updater. That updater bypasses the Nix pin and
          # the supply-chain cooldown, and the daemon keeps the environment
          # (e.g. proxy variables) of whichever session started it. Off here.
          # https://github.com/openai/codex/issues/48195
          daemonAutoStart = mkOption {
            type = types.nullOr types.bool;
            default = false;
            description = "Upstream [features] daemon_auto_start in Codex's writable config.toml; null leaves the key unmanaged and gives back a previously owned value.";
          };
        });

        content = {
          enable = mkEnableOption "standalone agent skills and global rules";
          artifacts = mkOption {
            type = types.raw;
            default = { };
            internal = true;
            description = "Content paths supplied to the integration aspect.";
          };
        };
        extraRules = mkOption {
          type = types.listOf types.path;
          default = [ ];
          description = "Markdown rule files contributed by imported aspects, delivered with the shared rules.";
        };
        atlassian.enable = mkEnableOption "Atlassian MCP and the Jira/Bitbucket skills";
        superlite.enable = mkEnableOption "the opt-in +agent-claude-superlite wrapper (the plugin is never loaded into plain claude)";

        mcp = {
          enable = mkEnableOption "MCP server wrappers, exports and client integration";
          clients = lib.genAttrs clientNames (name: {
            enable = mkOption {
              type = types.bool;
              default = true;
              description = "Integrate MCP into this Nix-managed agent; independent exports remain available.";
            };
            exclude = mkOption {
              type = types.listOf types.str;
              # Skills replace Atlassian for these clients.
              default = lib.optionals (builtins.elem name [ "claude" "antigravity" ]) [ "atlassian" ];
              description = "Server names omitted from this client's integration and exports.";
            };
          });
          exports = mkOption {
            type = types.listOf (types.enum clientNames);
            default = [ ];
            description = "Standalone client formats to export under XDG_CONFIG_HOME/ai/mcp, without installing agents.";
          };
          servers = mkOption {
            default = { };
            description = "Shared MCP catalog. Credentials are runtime secret-file references, never values.";
            type = types.attrsOf (types.submodule {
              options = {
                enable = mkOption {
                  type = types.bool;
                  default = true;
                  description = "Expose this server to clients and exports; keep its wrapper installed when disabled.";
                };
                stdio = mkOption { type = types.package; };
                remote = mkOption {
                  default = null;
                  type = types.nullOr (types.submodule {
                    options = {
                      url = mkOption { type = types.str; };
                      auth = mkOption {
                        default = null;
                        type = types.nullOr (types.submodule {
                          options = {
                            kind = mkOption { type = types.enum [ "bearer" ]; };
                            secret = mkOption { type = types.strMatching "[a-zA-Z0-9_-]+"; };
                            var = mkOption { type = types.strMatching "[A-Z_][A-Z0-9_]*"; };
                          };
                        });
                      };
                    };
                  });
                };
              };
            });
          };
          rendered = mkOption {
            type = types.raw;
            default = { };
            internal = true;
            description = "Client configurations consumed by the integration aspect.";
          };
        };
      };
    };
}
