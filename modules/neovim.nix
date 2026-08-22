# Neovim (nvf), in two variants.
#
#   homeManager.neovim         workstation: every language toolchain enabled
#   homeManager.neovim-server  servers: the same editor, none of the toolchains
#
# WHY THE SPLIT. `languages.<lang>.enable` in nvf does not just add a treesitter
# grammar — it puts that language's LSP, formatter and linter into the closure,
# and those drag whole SDKs. Measured in the p-ion-berlin-xs56r6 closure before this split:
#
#     llvm-21.1.8-lib          261 MiB   languages.clang
#     go-1.26.5                244 MiB   languages.go
#     helix-grammars           185 MiB   programs.helix
#     tinymist                 174 MiB   languages.typst
#     metals-deps              120 MiB   languages.scala
#     basedpyright-npm-deps    114 MiB   languages.python
#     harper                   112 MiB   lsp.presets.harper
#     openjdk-headless          55 MiB   languages.java
#     … plus nodejs, biome, mypy, cmake, rust-lib-src, python3 x2
#
# modules/hosts/p-ion-berlin-xs56r6.nix already refuses `homeManager.packages` with the
# note "~144 entries — the whole AI toolchain on a 4 GB server". This is the same
# mistake arriving through a different door: a 4 GB / 120 GB VPS was being handed
# a full multi-language IDE so that root could edit a config file.
#
# RESULT, measured with `nix path-info -S` on the built toplevel:
#
#     before   never finished — 1 h 37 m of substitution, killed while still
#              fetching rustc and clang-lib; 6570 derivations, 286 tree-sitter
#              grammars
#     after    1.88 GiB across 941 paths; 5693 derivations, 24 grammars
#
# The remaining 84 MiB of nodejs is `bash.enable` -> bash-language-server, kept
# on purpose: shell highlighting is the one thing a server editor is actually
# for. The largest single path left (196 MiB) is not nvf at all — it is the
# nixpkgs source tree, pinned into /etc/nix/registry.json by
# `nixpkgs.flake.setFlakeRegistry`/`setNixPath`, both of which default to true.
#
# THE INVARIANT: `neovim` = `common` + `workstation`, and that union is exactly
# what this file configured before the split. Consequently `common` may only ever
# LOSE things to `workstation` — never gain anything of its own, or both hosts
# change at once. Server-only additions go in the `server` attrset, which no
# workstation imports.
#
# How to check that after editing here — and note WHICH check, because the
# obvious one gives a false alarm:
#
#   nix eval --raw .#darwinConfigurations.FCX19GT9XR.system.drvPath
#
# is too strict. Splitting one module into two shifted exactly one element
# (`worktrunk`) in home-manager's `home.packages` list, which changes the system
# derivation hash while installing the identical set. Compare CONTENT instead:
#
#   # the editor itself — must be byte-identical
#   nix eval --raw .#darwinConfigurations.FCX19GT9XR.config.home-manager\
#     .users.stefan.programs.nvf.finalPackage.drvPath
#
#   # the package set — sort first, order is not meaningful
#   nix eval --raw .#darwinConfigurations.FCX19GT9XR.config.home-manager\
#     .users.stefan.home.packages \
#     --apply 'ps: builtins.concatStringsSep "\n" (builtins.sort (a: b: a < b) (map (p: p.outPath) ps))'
#
# Both were verified equal across this split: 163 identical store paths, and
# nvf-with-helpers at the same drv path before and after.
{ inputs, ... }:
let
  # Editor, UI, git, motions and the LSP framework itself. Nothing here pulls a
  # language toolchain, so it is safe on a small server.
  common = { pkgs, ... }: {
    imports = [ inputs.nvf.homeManagerModules.default ];

    programs.nvf = {
      enable = true;

      settings = {
        vim = {
          viAlias = true;
          vimAlias = true;

          clipboard = {
            registers = [ "unnamedplus" ];
          };

          theme = {
            enable = true;
            name = "catppuccin";
            style = "mocha";
          };

          statusline.lualine.enable = true;

          visuals = {
            nvim-scrollbar.enable = true;
            nvim-web-devicons.enable = true;
            nvim-cursorline.enable = true;
            cinnamon-nvim.enable = true;
            fidget-nvim.enable = true;
            highlight-undo.enable = true;
            indent-blankline.enable = true;
          };

          telescope.enable = true;
          filetree.neo-tree.enable = true;

          languages = {
            enableFormat = true;
            enableTreesitter = true;
            enableExtraDiagnostics = true;
            # Only the two that cost nothing measurable. Everything else —
            # including `lua` and `json`, which do not look expensive but are —
            # lives in `workstation` below. Measured in the server closure:
            #   lua  -> luacheck -> luarocks_bootstrap -> cmake        61 MiB
            #   json -> vscode-langservers-extracted -> nodejs-slim    84 MiB
            bash.enable = true;
            just.enable = true;
          };

          lsp = {
            enable = true;
            formatOnSave = true;
            lspkind.enable = false;
            lightbulb.enable = true;
            lspsaga.enable = false;
            trouble.enable = true;
            lspSignature.enable = false;
            otter-nvim.enable = true;
            nvim-docs-view.enable = true;
          };

          autocomplete = {
            nvim-cmp.enable = false;
            blink-cmp.enable = true;
          };

          autopairs.nvim-autopairs.enable = true;
          snippets.luasnip.enable = true;
          tabline.nvimBufferline.enable = true;
          treesitter.context.enable = true;
          comments.comment-nvim.enable = true;

          git.enable = true;
          git.gitsigns.enable = true;
          git.gitsigns.codeActions.enable = false;
          git.neogit.enable = true;

          binds = {
            whichKey.enable = true;
            cheatsheet.enable = true;
          };

          ui = {
            borders.enable = true;
            noice.enable = true;
            colorizer.enable = true;
            illuminate.enable = true;
            breadcrumbs = {
              enable = true;
              navbuddy.enable = true;
            };
            smartcolumn = {
              enable = true;
              setupOpts.custom_colorcolumn = {
                nix = "110";
                ruby = "120";
                java = "130";
                go = [ "90" "130" ];
              };
            };
            fastaction.enable = true;
          };

          minimap = {
            # codewindow.nvim requires the legacy `nvim-treesitter.ts_utils`,
            # removed in nvim-treesitter's main-branch rewrite that nvf now
            # bundles. Use minimap-vim (code-minimap based, treesitter-free).
            #
            # There is deliberately no `codewindow.enable = false;` here any more.
            # nvf reached the same conclusion and DELETED the option (its
            # mkRemovedOptionModule says "Disabled, because it doesn't support
            # tree-sitter main branch"), and that flavour of removal asserts on
            # `isDefined` — so even setting it to `false` fails evaluation:
            #
            #   error: Failed assertions:
            #   - The option definition `vim.minimap.codewindow.enable' … no longer
            #     has any effect; please remove it.
            #
            # Do not re-add it "for explicitness". Verified 2026-08-22 against nvf
            # main b05fadedb and af19044e; both fail.
            #
            # Kept in `common` although it is not strictly needed on a server:
            # code-minimap is a couple of MB, and its keymap lives in the shared
            # `keymaps` list below. Splitting the plugin from its binding would
            # mean splitting that list, and a list defined in two modules merges
            # in an order the module system does not promise — which would move
            # the workstation derivation and break the invariant above.
            minimap-vim.enable = true;
          };

          dashboard = {
            dashboard-nvim.enable = false;
            alpha.enable = true;
          };

          notify.nvim-notify.enable = true;
          projects.project-nvim.enable = true;

          terminal.toggleterm = {
            enable = true;
            lazygit.enable = true;
          };

          utility = {
            ccc.enable = false;
            vim-wakatime.enable = false;
            diffview-nvim.enable = true;
            yanky-nvim.enable = false;
            qmk-nvim.enable = false;
            icon-picker.enable = true;
            surround.enable = true;
            multicursors.enable = true;
            smart-splits.enable = true;
            undotree.enable = true;
            nvim-biscuits.enable = true;
            motion = {
              hop.enable = true;
              leap.enable = true;
              precognition.enable = true;
            };
            images = {
              image-nvim.enable = false;
            };
          };

          notes = {
            neorg.enable = false;
            orgmode.enable = false;
            # mind.nvim was removed in nvf 0.9 (upstream repo deleted).
            todo-comments.enable = true;
          };

          assistant = {
            chatgpt.enable = false;
            copilot = {
              enable = false;
              cmp.enable = true;
            };
            codecompanion-nvim.enable = false;
          };

          startPlugins = [
            pkgs.vimPlugins.vim-gnupg
          ];

          luaConfigRC.gnupg_setup = ''
            -- vim-gnupg requires GPG_TTY environment variable
            -- Already configured in user's shell
          '';

          keymaps = [
            {
              key = "<S-F19>";
              mode = [ "n" "x" "o" ];
              action = "function () require('leap').leap { target_windows = require('leap.util').get_focusable_windows(), windows = require('leap.util').get_focusable_windows(), inclusive = true } end";
              lua = true;
              desc = "Leap (anywhere)";
              silent = true;
            }
            {
              key = "<leader>mm";
              mode = [ "n" ];
              action = "<cmd>MinimapToggle<CR>";
              desc = "Toggle minimap";
              silent = true;
            }
          ];
        };
      };
    };
  };

  # Everything with an SDK, a second editor, or a desktop assumption behind it.
  # This is the part a server does not get.
  workstation = { ... }: {
    programs.helix = {
      enable = true;
      settings = {
        editor = {
          bufferline = "multiple";
        };
      };
    };

    programs.nvf.settings.vim = {
      languages = {
        clang.enable = true;
        css.enable = true;
        html.enable = true;
        sql.enable = true;
        # Moved out of `common` on measurement, not on principle: `lua` drags
        # luacheck -> luarocks -> cmake (61 MiB) and `json` drags
        # vscode-langservers-extracted -> nodejs-slim (84 MiB). The union with
        # `common` is unchanged, so the workstation is unaffected.
        lua.enable = true;
        json.enable = true;
        java.enable = true;
        kotlin.enable = true;
        # nvf 0.9 renamed `languages.ts` → `languages.typescript` and split
        # JSX/TSX out into the separate `languages.tsx` module.
        typescript.enable = true;
        tsx.enable = true;
        go.enable = true;
        zig.enable = true;
        python.enable = true;
        typst.enable = true;
        rust = {
          enable = true;
          extensions.crates-nvim.enable = true;
        };
        scala.enable = true;
      };

      # nvf 0.9 moved `lsp.harper-ls` → `lsp.presets.harper`. ~112 MiB of
      # grammar model, which is not what a server is for.
      lsp.presets.harper.enable = true;

      utility = {
        leetcode-nvim.enable = true;
        images.img-clip.enable = true;
      };

      notes.obsidian = {
        enable = true;
        # obsidian.nvim (obsidian-nvim/obsidian.nvim fork) runs each
        # workspace path through vim.fs.normalize, which expands ~ and
        # env vars — so this stays portable across both Macs.
        setupOpts.workspaces = [
          {
            name = "work_notes";
            path = "~/Documents/Obsidian/work_notes";
          }
        ];
      };

      assistant.avante-nvim.enable = true;
    };
  };

  # Server-only additions. Nothing here reaches a workstation, so this attrset
  # is the safe place to add things the servers want and the Macs do not.
  server = { ... }: {
    programs.nvf.settings.vim.languages = {
      # Editing a NixOS configuration in place is the one language job a server
      # genuinely has, and nixd is small.
      nix.enable = true;

      # Deliberately NOT markdown, and this one is counter-intuitive enough to
      # write down: nvf's markdown module pulls `marksman` (an LSP written in
      # .NET, so it drags dotnet-runtime, 76 MiB) and formats with `deno`
      # (136 MiB). 212 MiB so that root can edit a README on a 4 GB VPS.
      #
      # Also not yaml: yaml-language-server is an npm package, so it would put
      # nodejs back after `json` was moved out of `common` to remove it.
    };
  };
in
{
  flake.modules.homeManager.neovim = { imports = [ common workstation ]; };
  flake.modules.homeManager.neovim-server = { imports = [ common server ]; };
}
