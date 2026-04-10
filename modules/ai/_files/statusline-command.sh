#!/bin/sh
# Claude Code statusLine command
# Displays: directory, git branch, model (short), context %, tokens, rate limit, starship language modules

input=$(cat)

cwd=$(echo "$input" | jq -r '.cwd // .workspace.current_dir // "?"')
model_full=$(echo "$input" | jq -r '.model.display_name // "?"')
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
total_input=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
total_output=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')
five_hour_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')

# Shorten model name: strip "Claude " prefix, shorten "Sonnet"/"Haiku"/"Opus" to 3 letters + version
# e.g. "Claude 3.5 Sonnet" -> "3.5 Son"  "Claude Sonnet 4.5" -> "Son 4.5"
model=$(echo "$model_full" \
    | sed 's/^Claude //' \
    | sed 's/Sonnet/Son/g' \
    | sed 's/Haiku/Hku/g' \
    | sed 's/Opus/Ops/g')

# Shorten home directory to ~
home="$HOME"
short_cwd=$(echo "$cwd" | sed "s|^$home|~|")

# Get git branch (skip optional locks to avoid conflicts)
git_branch=$(git -C "$cwd" --no-optional-locks branch --show-current 2>/dev/null)

# Build the status line parts

# Directory
parts="${short_cwd}"

# Git branch
if [ -n "$git_branch" ]; then
    parts="${parts}  ${git_branch}"
fi

# Separator
parts="${parts}   "

# Model (shortened)
parts="${parts}${model}"

# Context usage
if [ -n "$used_pct" ]; then
    used_rounded=$(printf "%.0f" "$used_pct")
    parts="${parts}  ctx:${used_rounded}%"
fi

# Token totals
total_tok=$((total_input + total_output))
if [ "$total_tok" -gt 0 ]; then
    if [ "$total_tok" -ge 1000 ]; then
        total_k=$(echo "$total_tok" | awk '{printf "%.1fk", $1/1000}')
        parts="${parts}  tok:${total_k}"
    else
        parts="${parts}  tok:${total_tok}"
    fi
fi

# 5-hour rate limit
if [ -n "$five_hour_pct" ]; then
    five_rounded=$(printf "%.0f" "$five_hour_pct")
    parts="${parts}  5h:${five_rounded}%"
fi

# Starship language/tool modules — run in cwd, strip ANSI escapes, trim brackets/spaces
strip_ansi() {
    printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g'
}

starship_modules="java python nodejs golang rust ruby php swift kotlin scala lua perl zig elixir erlang dart haskell nim ocaml raku vlang"

lang_parts=""
for mod in $starship_modules; do
    raw=$(starship module "$mod" --path "$cwd" 2>/dev/null)
    if [ -n "$raw" ]; then
        clean=$(strip_ansi "$raw" | tr -d '\n' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
        if [ -n "$clean" ]; then
            lang_parts="${lang_parts} ${clean}"
        fi
    fi
done

if [ -n "$lang_parts" ]; then
    parts="${parts}  |${lang_parts}"
fi

printf "%s" "$parts"
