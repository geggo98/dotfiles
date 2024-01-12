set fish_greeting # Disable greeting

if command -v starship > /dev/null
    starship init fish | source
end
if command -v nvim > /dev/null
    set -x MANPAGER "$(command -v nvim) +Man!"
    set -x MANWIDTH 999
end
if command -v bat > /dev/null
    set -x PAGER (command -v bat)
    set -x FZF_PREVIEW_FILE_CMD "fzf --preview \"bat --color=always --style=numbers --line-range=:500 {}\"" 
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

test -e {$HOME}/.iterm2_shell_integration.fish ; and source {$HOME}/.iterm2_shell_integration.fish
test -d {$HOME}/.iterm2 ; and fish_add_path {$HOME}/.iterm2 
