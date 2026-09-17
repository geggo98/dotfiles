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
            default = "gpt-5.6-sol";
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
          # Upstream feature flag, managed and deliberately OFF.
          #
          # openai/codex added `[features] reasoning_effort_override` in PR #43110,
          # first shipped in 0.154.0 (2026-09-09); it is still Stage::UnderDevelopment
          # and default-off upstream. With it enabled, codex appends a
          # `configuration_update` history item whenever the resolved reasoning
          # effort changes mid-session -- which entering Plan mode ALWAYS does here,
          # because planReasoningEffort ("xhigh") differs from reasoningEffort
          # ("medium"). gpt-5.6-luna, -terra and -sol then answer HTTP 400 on every
          # following turn; only gpt-6-astra tolerates the item. Open, unfixed as of
          # 2026-09-17, and `false` is the issue's own stated workaround:
          # https://github.com/openai/codex/issues/44751
          #
          # Inert on the currently pinned codex 0.153.4 (modules/agents.nix, input
          # llm-agents-codex-pin): that build has no such flag, and Features is a
          # flattened BTreeMap<String,bool>, so the key parses and is only logged as
          # "unknown feature key in config" under RUST_LOG=warn. Written now so the
          # flag is already off on the day the pin advances past 0.154.0 rather than
          # after the first 400.
          reasoningEffortOverride = mkOption {
            type = types.nullOr types.bool;
            default = false;
            description = "Upstream [features] reasoning_effort_override in Codex's writable config.toml; null leaves the key unmanaged and gives back a previously owned value.";
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
