#!/bin/sh
# Claude Code statusLine command
# Displays: worktree path + git/CI status (Worktrunk), model (short), context %,
# tokens, weekly rate limit + projection, starship language modules

input=$(cat)

cwd=$(echo "$input" | jq -r '.cwd // .workspace.current_dir // "?"')
model_full=$(echo "$input" | jq -r '.model.display_name // "?"')
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
total_input=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
total_output=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')

# Weekly limit (there is no 5h window any more) plus a projection to the reset.
# Window start is not documented; assumed = resets_at - 7d. Projection = average
# pace so far, extrapolated to the reset. Empty output when no seven_day window.
#   7d:42% →78% 🟡 ↻2d5h            reaches the reset with reserve / just about
#   7d:65% →140% 🔴 leer 1d8h ↻3d2h  runs out 1d8h from now, 3d2h before the reset
# No projection in the first 5% of the window (~8h): the extrapolation is noise.
week_seg=$(echo "$input" | jq -r '
  def dur(s): (s | floor) as $s
    | if $s >= 86400 then "\($s / 86400 | floor)d\(($s % 86400) / 3600 | floor)h"
      else "\($s / 3600 | floor)h\(($s % 3600) / 60 | floor)m" end;
  604800 as $week
  | (.rate_limits.seven_day // empty) as $w
  | ($w.used_percentage // empty) as $u
  | ($w.resets_at // 0) as $r
  | ($r - now) as $left
  | (if $left > 0 then ([($week - $left) / $week, 0] | max) else null end) as $f
  | "7d:\($u | round)%"
    + (if $f == null then ""
       elif $u >= 100 then " 🔴 ↻" + dur($left)
       elif $f < 0.05 then " ↻" + dur($left)
       else ($u / $f) as $p
         | " →\($p | round)% " + (if $p <= 70 then "🟢" elif $p <= 100 then "🟡" else "🔴" end)
           + (if $p > 100 then " leer " + dur((100 - $u) / ($u / ($f * $week))) else "" end)
           + " ↻" + dur($left)
       end)
' 2>/dev/null)

# Shorten model name: strip "Claude " prefix, shorten "Sonnet"/"Haiku"/"Opus" to 3 letters + version
# e.g. "Claude 3.5 Sonnet" -> "3.5 Son"  "Claude Sonnet 4.5" -> "Son 4.5"
model=$(echo "$model_full" \
    | sed 's/^Claude //' \
    | sed 's/Sonnet/Son/g' \
    | sed 's/Haiku/Hku/g' \
    | sed 's/Opus/Ops/g')

# Head segment: Worktrunk's abbreviated path + worktree/git/CI status, with a
# pure-shell fallback.

# Fish-style path abbreviation: ~/dev/work/project -> ~/d/w/project (shorten every path
# component except the last; $HOME -> ~). Used only by the fallback below.
abbreviate_path() {
    printf '%s' "$1" | sed "s|^$HOME|~|" | awk -F/ '{
        out = "";
        for (i = 1; i <= NF; i++) {
            s = $i;
            if (i < NF && length(s) > 0 && s != "~") s = substr(s, 1, 1);
            out = (i == 1) ? s : out "/" s;
        }
        print out;
    }'
}

# Ask Worktrunk for the rich head segment. Feed it NO JSON on stdin (</dev/null):
# with empty stdin `wt` emits only the git-derived part (abbreviated path,
# worktree markers, ahead/behind, diffstat, CI/PR) and omits model/context/
# rate-limit — which we render ourselves below. Always wrapped in `gtimeout` so a
# cold CI-cache network fetch can never stall the statusline.
head_seg=""
if command -v wt >/dev/null 2>&1; then
    if command -v gtimeout >/dev/null 2>&1; then
        head_seg=$(cd "$cwd" 2>/dev/null && gtimeout 3 wt list statusline --format=claude-code </dev/null 2>/dev/null)
    else
        # gtimeout absent (unexpected on this host): run wt directly rather than skip it.
        head_seg=$(cd "$cwd" 2>/dev/null && wt list statusline --format=claude-code </dev/null 2>/dev/null)
    fi
fi

# Fallback on any wt failure (missing binary, gtimeout kill, error exit, or empty
# output outside a git repo): abbreviated path + branch, pure shell, never fails.
if [ -z "$head_seg" ]; then
    head_seg=$(abbreviate_path "$cwd")
    git_branch=$(git -C "$cwd" --no-optional-locks branch --show-current 2>/dev/null)
    if [ -n "$git_branch" ]; then
        head_seg="${head_seg}  ${git_branch}"
    fi
fi

# Build the status line parts

# Head segment (path + git/CI)
parts="${head_seg}"

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

# Weekly rate limit with projection
if [ -n "$week_seg" ]; then
    parts="${parts}  ${week_seg}"
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

# AI provider status (ai-watch.dev): up to 3 non-operational AI services, each
# prefixed 🔴 (e.g. "🔴 Claude API 🔴 OpenAI API"). curl self-caps with
# --max-time 2, but wrap the whole curl|jq pipe in gtimeout too (like the wt
# call above) so a stalled connection can never hang the statusline. Any
# failure (offline, DNS, non-zero exit) or all-operational -> empty string,
# and the segment below is skipped.
ai_jq='[.services[] | select(.status != "operational") | "🔴 " + .name] | .[0:3] | join(" ")'
ai_fetch='curl -sf --max-time 2 https://ai-watch.dev/api/status/cached | jq -r "$1"'
if command -v gtimeout >/dev/null 2>&1; then
    ai_status=$(gtimeout 3 sh -c "$ai_fetch" _ "$ai_jq" 2>/dev/null || true)
else
    # gtimeout absent (unexpected): rely on curl --max-time alone.
    ai_status=$(sh -c "$ai_fetch" _ "$ai_jq" 2>/dev/null || true)
fi

if [ -n "$ai_status" ]; then
    # Make the 🔴 block a clickable OSC 8 hyperlink to ai-watch.dev. The ESC
    # bytes are materialized by printf inside a command substitution, so the
    # final `printf "%s" "$parts"` emits them verbatim. Terminals without OSC 8
    # support (e.g. Terminal.app) simply render the plain text unchanged.
    ai_status=$(printf '\033]8;;https://ai-watch.dev/\033\\%s\033]8;;\033\\' "$ai_status")
    parts="${parts}   ${ai_status}"
fi

printf "%s" "$parts"
