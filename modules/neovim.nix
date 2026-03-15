{ inputs, ... }:
{
  flake.modules.homeManager.neovim = { pkgs, ... }: {
    imports = [ inputs.nvf.homeManagerModules.default ];

    programs.helix = {
      enable = true;
      settings = {
        editor = {
          bufferline = "multiple";
        };
      };
    };

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
            bash.enable = true;
            clang.enable = true;
            css.enable = true;
            html.enable = true;
            json.enable = true;
            sql.enable = true;
            java.enable = true;
            kotlin.enable = true;
            ts.enable = true;
            go.enable = true;
            lua.enable = true;
            zig.enable = true;
            python.enable = true;
            typst.enable = true;
            rust = {
              enable = true;
              extensions.crates-nvim.enable = true;
            };
            scala.enable = true;
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
            harper-ls.enable = true;
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
            minimap-vim.enable = false;
            codewindow.enable = true;
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
            leetcode-nvim.enable = true;
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
              img-clip.enable = true;
            };
          };

          notes = {
            obsidian.enable = false;
            neorg.enable = false;
            orgmode.enable = false;
            mind-nvim.enable = true;
            todo-comments.enable = true;
          };

          assistant = {
            chatgpt.enable = false;
            copilot = {
              enable = false;
              cmp.enable = true;
            };
            codecompanion-nvim.enable = false;
            avante-nvim.enable = true;
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
          ];
        };
      };
    };
  };
}
