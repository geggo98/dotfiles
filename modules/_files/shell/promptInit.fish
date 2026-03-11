set fish_greeting # Disable greeting

function fix_nix_sops_secret_path --argument secret_path --description "Fix the path to a Nix SOPS secret"
    if test -z "$nix_sops_secrets_base_path"
        # Determine the base path for secrets. On Linux, it's $XDG_RUNTIME_DIR. On macOS Darwin it's `getconf DARWIN_USER_TEMP_DIR`.
        if command -v getconf > /dev/null
            set -g nix_sops_secrets_base_path (getconf DARWIN_USER_TEMP_DIR)
        else
            set -g nix_sops_secrets_base_path $XDG_RUNTIME_DIR
        end
    end
    # In the paramter secret_path, replace `%r` with secret base path
    set -f secret_path (string replace '%r' $nix_sops_secrets_base_path $secret_path)
    echo $secret_path
end

function export_nix_sops_secret_path --argument variable_name --argument secret_path --description "Export the path to a Nix SOPS secret"
    set -g -x $variable_name (fix_nix_sops_secret_path $secret_path)
end

function export_nix_sops_secret_value --argument variable_name --argument secret_path --description "Export the value of a Nix SOPS secret"
    set -f secret_path (fix_nix_sops_secret_path $secret_path)
    if test -f "$secret_path"
        set -g -x $variable_name (cat $secret_path)
    end
end

if command -v starship > /dev/null
#    starship init fish | source
    function starship_transient_rprompt_func
        starship module directory
    end
end
if command -v nvim > /dev/null
    set -x MANPAGER "$(command -v nvim) +Man!"
    set -x MANWIDTH 999
end
if command -v bat > /dev/null
    set -x PAGER (command -v bat)
    set -x FZF_PREVIEW_FILE_CMD 'fzf --preview "bat --color=always --style=numbers --line-range=:500 {}"' 
end
if command -v lsd > /dev/null
    set -x FZF_PREVIEW_DIR_CMD "lsd -a"
end

if command -v nvim > /dev/null
    set -x EDITOR nvim
    set -x VISUAL nvim
    set -x GIT_EDITOR nvim
else
    set -x EDITOR vim
    set -x VISUAL vim
    set -x GIT_EDITOR vim
end

if command -v /opt/homebrew/bin/brew > /dev/null
    /opt/homebrew/bin/brew shellenv | source
else if command -v /usr/local/bin/brew > /dev/null
    /usr/local/bin/brew shellenv | source
end

if test -e {$HOME}/.iterm2_shell_integration.fish
    source {$HOME}/.iterm2_shell_integration.fish
    if functions fish_prompt > /dev/null 
        # random 100000000000 1000000000000
        functions --copy fish_prompt fish_prompt_old_892546889851
        function fish_prompt
            iterm2_prompt_mark
            fish_prompt_old_892546889851
        end
    end
end
test -d {$HOME}/.iterm2 ; and fish_add_path {$HOME}/.iterm2 
