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
