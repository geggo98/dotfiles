set fish_greeting # Disable greeting

function read_nix_sops_secret --argument secret_path
    # Determine the base path for secrets. On Linux, it's $XDG_RUNTIME_DIR. On macOS Darwin it's `getconf DARWIN_USER_TEMP_DIR`.
    if command -v getconf > /dev/null
        set secrets_base_path (getconf DARWIN_USER_TEMP_DIR)
    else
        set secrets_base_path $XDG_RUNTIME_DIR
    end
    # In the paramter secret_path, replace `%r` with secret base path with the Fish stirng function
    set secret_path (string replace '%r' $secrets_base_path $secret_path)
    # If the file exists, read it and set the environment variable $secret_name
    if test -f "$secret_path"
        cat $secret_path
    end 
end

# If the variable $OPEN_AI_API_KEY_FILE is defined, read it and set the environment variable $OPEN_AI_API_KEY
if set -q OPEN_AI_API_KEY_FILE
    set -x OPEN_AI_API_KEY (read_nix_sops_secret $OPEN_AI_API_KEY_FILE)
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

if test -f ~/.config/nvim/init.lua > /dev/null
    set -x VISUAL nvim
    set -x GIT_EDITOR nvim
else if command -v {$HOME}/.local/bin/lvim > /dev/null
    alias lvim {$HOME}/.local/bin/lvim
    set -x VISUAL /{$HOME}/.local/bin/lvim
    set -x GIT_EDITOR /{$HOME}/.local/bin/lvim
else
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
