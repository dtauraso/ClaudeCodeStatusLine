#!/bin/bash
# Labeled status line for Claude Code
# Layout:
#   Opus 4.8 · effort: max                            v2.1.160
#   wirefold · task/some-branch · +20 −19
#
#   Chat context   ███████  8%   87K / 1M tokens
#   Plan · 5-hour  ███████  3%   resets in 1h47m  (16:20)
#   Plan · weekly  ███████  2%   resets in 1d21h  (Thu 12:00)

set -f  # disable globbing

input=$(cat)

if [ -z "$input" ]; then
    printf "Claude"
    exit 0
fi

# ===== ANSI colors =====
blue='\033[38;2;0;153;255m'
orange='\033[38;2;255;176;85m'
green='\033[38;2;0;160;0m'
cyan='\033[38;2;46;149;153m'
red='\033[38;2;255;85;85m'
yellow='\033[38;2;230;200;0m'
purple='\033[38;2;167;139;250m'
white='\033[38;2;220;220;220m'
dim='\033[2m'
bold='\033[1m'
reset='\033[0m'

# ===== Helpers =====

# Format token count compactly: 87000 → "87K", 1000000 → "1M"
format_tokens() {
    local num=$1
    if [ "$num" -ge 1000000 ]; then
        awk "BEGIN {v=sprintf(\"%.1f\",$num/1000000)+0; if(v==int(v)) printf \"%dM\",v; else printf \"%.1fM\",v}"
    elif [ "$num" -ge 1000 ]; then
        awk "BEGIN {v=sprintf(\"%.0f\",$num/1000)+0; printf \"%dK\",v}"
    else
        printf "%d" "$num"
    fi
}

# Render a progress bar using block chars.
# Usage: render_bar <pct_integer> <width>  → prints e.g. "██░░░░░"
# <width> defaults to $bar_width (set from terminal width calculation above).
render_bar() {
    local pct=$1
    local w=${2:-$bar_width}
    # Use ceiling so even 1% shows one filled block
    local filled=$(( (pct * w + 99) / 100 ))
    [ "$pct" -eq 0 ] && filled=0
    [ "$filled" -gt "$w" ] && filled=$w
    local empty=$(( w - filled ))
    local bar=""
    local i
    for (( i=0; i<filled; i++ )); do bar+="█"; done
    for (( i=0; i<empty;  i++ )); do bar+="░"; done
    printf "%s" "$bar"
}

# Return a color escape based on usage percentage
usage_color() {
    local pct=$1
    if   [ "$pct" -ge 90 ]; then printf "%s" "$red"
    elif [ "$pct" -ge 70 ]; then printf "%s" "$orange"
    elif [ "$pct" -ge 50 ]; then printf "%s" "$yellow"
    else                         printf "%s" "$green"
    fi
}

# Convert ISO 8601 or Unix epoch string to epoch seconds (cross-platform)
to_epoch() {
    local s="$1"
    # If it's a plain integer treat it as epoch already
    if [[ "$s" =~ ^[0-9]+$ ]]; then
        echo "$s"
        return
    fi
    # GNU date
    local ep
    ep=$(date -d "$s" +%s 2>/dev/null)
    [ -n "$ep" ] && { echo "$ep"; return; }
    # BSD date (macOS)
    local stripped="${s%%.*}"
    stripped="${stripped%%Z}"
    stripped="${stripped%%+*}"
    if [[ "$s" == *"Z"* ]] || [[ "$s" == *"+00:00"* ]]; then
        ep=$(env TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
    else
        ep=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
    fi
    [ -n "$ep" ] && echo "$ep"
}

# Format relative time from now until epoch
# Returns e.g. "1h47m", "2d3h", "45m", "now"
relative_time() {
    local target_epoch="$1"
    local now
    now=$(date +%s)
    local diff=$(( target_epoch - now ))
    if [ "$diff" -le 0 ]; then
        echo "now"
        return
    fi
    local days=$(( diff / 86400 ))
    local hrs=$(( (diff % 86400) / 3600 ))
    local mins=$(( (diff % 3600) / 60 ))

    if   [ "$days" -ge 2 ]; then printf "%dd%dh" "$days" "$hrs"
    elif [ "$days" -ge 1 ]; then printf "%dd%dh" "$days" "$hrs"
    elif [ "$hrs"  -ge 1 ]; then printf "%dh%dm" "$hrs"  "$mins"
    else                         printf "%dm"     "$mins"
    fi
}


# ===== OAuth token resolution (for API fallback) =====
claude_config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

get_oauth_token() {
    if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
        echo "$CLAUDE_CODE_OAUTH_TOKEN"; return 0
    fi
    if command -v security >/dev/null 2>&1; then
        local svc="Claude Code-credentials"
        if [ -n "$CLAUDE_CONFIG_DIR" ]; then
            local h; h=$(echo -n "$CLAUDE_CONFIG_DIR" | shasum -a 256 | cut -c1-8)
            svc="Claude Code-credentials-${h}"
        fi
        local blob; blob=$(security find-generic-password -s "$svc" -w 2>/dev/null)
        if [ -n "$blob" ]; then
            local tok; tok=$(echo "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
            [ -n "$tok" ] && [ "$tok" != "null" ] && { echo "$tok"; return 0; }
        fi
    fi
    local cf="${claude_config_dir}/.credentials.json"
    if [ -f "$cf" ]; then
        local tok; tok=$(jq -r '.claudeAiOauth.accessToken // empty' "$cf" 2>/dev/null)
        [ -n "$tok" ] && [ "$tok" != "null" ] && { echo "$tok"; return 0; }
    fi
    echo ""
}

# ===== Extract data from JSON input =====
model_raw=$(echo "$input" | jq -r '.model.display_name // "Claude"')
# Strip "(1M context)" suffix; keep just the name and optional size
model_name=$(echo "$model_raw" | sed 's/ *([^)]*context)//')

# Effort level
effort_level=""
stdin_effort=$(echo "$input" | jq -r '.effort.level // empty' 2>/dev/null)
if [ -n "$stdin_effort" ]; then
    effort_level="$stdin_effort"
elif [ -n "$CLAUDE_CODE_EFFORT_LEVEL" ]; then
    effort_level="$CLAUDE_CODE_EFFORT_LEVEL"
elif [ -f "${claude_config_dir}/settings.json" ]; then
    effort_level=$(jq -r '.effortLevel // empty' "${claude_config_dir}/settings.json" 2>/dev/null)
fi
[ -z "$effort_level" ] && effort_level="medium"

# CLI version from stdin
cli_version=$(echo "$input" | jq -r '.version // empty' 2>/dev/null)
# Fallback: cached version
cli_version_cache="/tmp/claude/statusline-cli-version"
if [ -z "$cli_version" ] && [ -f "$cli_version_cache" ]; then
    cli_version=$(cat "$cli_version_cache" 2>/dev/null)
fi
if [ -z "$cli_version" ]; then
    cli_version=$(claude --version 2>/dev/null | awk '{print $1}')
    [ -n "$cli_version" ] && { mkdir -p /tmp/claude; echo "$cli_version" > "$cli_version_cache"; }
fi

# Context window
ctx_size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
[ "$ctx_size" -eq 0 ] 2>/dev/null && ctx_size=200000
input_tokens=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0')
cache_create=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
cache_read=$(echo  "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
ctx_used=$(( input_tokens + cache_create + cache_read ))
if [ "$ctx_size" -gt 0 ]; then
    ctx_pct=$(( ctx_used * 100 / ctx_size ))
else
    ctx_pct=0
fi
[ "$ctx_pct" -gt 100 ] && ctx_pct=100
ctx_used_fmt=$(format_tokens "$ctx_used")
ctx_size_fmt=$(format_tokens "$ctx_size")

# CWD / git
cwd=$(echo "$input" | jq -r '.cwd // empty')
repo_name=""
git_branch=""
git_stat=""
if [ -n "$cwd" ]; then
    repo_name="${cwd##*/}"
    git_branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)
    raw_stat=$(git -C "$cwd" diff --numstat 2>/dev/null | awk '{a+=$1; d+=$2} END {if (a+d>0) printf "+%d −%d", a, d}')
    git_stat="$raw_stat"
fi

# Rate-limit data: prefer stdin rate_limits, fall back to API cache
builtin_fh_pct=$(echo  "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
builtin_fh_rst=$(echo  "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
builtin_sd_pct=$(echo  "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
builtin_sd_rst=$(echo  "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

use_builtin=false
if [ -n "$builtin_fh_pct" ] || [ -n "$builtin_sd_pct" ]; then
    # Trust builtin if non-zero or reset timestamps present
    if { [ -n "$builtin_fh_pct" ] && [ "$(printf '%.0f' "$builtin_fh_pct" 2>/dev/null)" != "0" ]; } || \
       { [ -n "$builtin_sd_pct" ] && [ "$(printf '%.0f' "$builtin_sd_pct" 2>/dev/null)" != "0" ]; } || \
       { [ -n "$builtin_fh_rst" ] && [ "$builtin_fh_rst" != "null" ] && [ "$builtin_fh_rst" != "0" ]; } || \
       { [ -n "$builtin_sd_rst" ] && [ "$builtin_sd_rst" != "null" ] && [ "$builtin_sd_rst" != "0" ]; }; then
        use_builtin=true
    fi
fi

# API cache fallback
cfg_hash=$(echo -n "$claude_config_dir" | shasum -a 256 2>/dev/null | cut -c1-8)
cache_file="/tmp/claude/statusline-usage-cache-${cfg_hash}.json"
cache_max_age=60
mkdir -p /tmp/claude

needs_refresh=true
usage_data=""
if [ -f "$cache_file" ] && [ -s "$cache_file" ]; then
    cm=$(stat -f %m "$cache_file" 2>/dev/null || stat -c %Y "$cache_file" 2>/dev/null)
    now_ts=$(date +%s)
    [ $(( now_ts - cm )) -lt "$cache_max_age" ] && needs_refresh=false
    usage_data=$(cat "$cache_file" 2>/dev/null)
fi
if $needs_refresh; then
    touch "$cache_file"
    token=$(get_oauth_token)
    if [ -n "$token" ] && [ "$token" != "null" ]; then
        resp=$(curl -s --max-time 10 \
            -H "Accept: application/json" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $token" \
            -H "anthropic-beta: oauth-2025-04-20" \
            -H "User-Agent: claude-code/2.1.34" \
            "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
        if [ -n "$resp" ] && echo "$resp" | jq -e '.five_hour' >/dev/null 2>&1; then
            usage_data="$resp"
            echo "$resp" > "$cache_file"
        fi
    fi
    [ -f "$cache_file" ] && [ ! -s "$cache_file" ] && rm -f "$cache_file"
fi

# Resolve final rate-limit numbers
fh_pct="" fh_rst_ep="" sd_pct="" sd_rst_ep=""

if $use_builtin; then
    fh_pct=$(printf "%.0f" "$builtin_fh_pct" 2>/dev/null)
    [ -n "$builtin_fh_rst" ] && [ "$builtin_fh_rst" != "null" ] && fh_rst_ep=$(to_epoch "$builtin_fh_rst")
    sd_pct=$(printf "%.0f" "$builtin_sd_pct" 2>/dev/null)
    [ -n "$builtin_sd_rst" ] && [ "$builtin_sd_rst" != "null" ] && sd_rst_ep=$(to_epoch "$builtin_sd_rst")
elif [ -n "$usage_data" ] && echo "$usage_data" | jq -e '.five_hour' >/dev/null 2>&1; then
    fh_pct=$(echo "$usage_data" | jq -r '.five_hour.utilization // 0' | awk '{printf "%.0f",$1}')
    fh_iso=$(echo "$usage_data" | jq -r '.five_hour.resets_at // empty')
    [ -n "$fh_iso" ] && fh_rst_ep=$(to_epoch "$fh_iso")
    sd_pct=$(echo "$usage_data" | jq -r '.seven_day.utilization // 0' | awk '{printf "%.0f",$1}')
    sd_iso=$(echo "$usage_data" | jq -r '.seven_day.resets_at // empty')
    [ -n "$sd_iso" ] && sd_rst_ep=$(to_epoch "$sd_iso")
fi

# ===== Terminal width =====
# Claude Code sets $COLUMNS to the live terminal width for statusLine commands.
# Fall back to tput cols (may return 80 when stdout is not a tty), then hard 80.
term_width=""
tput_val=$(tput cols 2>/dev/null)
if [[ -n "$COLUMNS" && "$COLUMNS" =~ ^[0-9]+$ && "$COLUMNS" -gt 0 ]]; then
    term_width="$COLUMNS"
elif [[ "$tput_val" =~ ^[0-9]+$ && "$tput_val" -gt 0 ]]; then
    term_width="$tput_val"
else
    term_width=80
fi

# Responsive bar width.
# Row layout (visible chars): label(15) + 1sp + bar + 1sp + pct(4) + 2sp + right_text
# Longest right_text is the weekly row: "resets in 6d23h" = 15 chars
# So max_non_bar = 15 + 1 + 1 + 4 + 2 + 15 = 38. (label-region 15 + 1 gap + pct 4 + 2 gap + reset 15)
# But label is 13 chars padded to LW=13, plus 2sp prefix = 15 total. So:
# max_non_bar = 13 + 2 + 1 + 4 + 2 + 15 = 37.
# Reserve an 8-col margin (~5-col frame padding + comfortable safety slack):
# bar_width = term_width - 37 - 8 = term_width - 45, clamped to [5, 50].
bar_width=$(( term_width - 45 ))
[ "$bar_width" -lt 5  ] && bar_width=5
[ "$bar_width" -gt 50 ] && bar_width=50

# ===== Render output =====

# --- Line 1: model · effort   [right pad]   vX.Y.Z ---
effort_color=""
case "$effort_level" in
    low)    effort_color="$dim" ;;
    medium) effort_color="$orange" ;;
    high)   effort_color="$green" ;;
    xhigh)  effort_color="$purple" ;;
    max)    effort_color="$red" ;;
    *)      effort_color="$green" ;;
esac

line1_left="${blue}${model_name}${reset} ${dim}·${reset} effort: ${effort_color}${effort_level}${reset}"
if [ -n "$cli_version" ]; then
    line1_right="${dim}v${cli_version}${reset}"
    printf '%b\n' "${line1_left}   ${line1_right}"
else
    printf '%b\n' "${line1_left}"
fi

# --- Line 2: repo · branch · diff stat ---
if [ -n "$repo_name" ]; then
    line2="${cyan}${repo_name}${reset}"
    if [ -n "$git_branch" ]; then
        line2+=" ${dim}·${reset} ${green}${git_branch}${reset}"
    fi
    if [ -n "$git_stat" ]; then
        # Split "+N −M" into parts; colour separately
        added="${git_stat%% *}"        # e.g. "+20"
        removed="${git_stat##* }"      # e.g. "−19"
        line2+=" ${dim}·${reset} ${green}${added}${reset} ${red}${removed}${reset}"
    fi
    printf '%b\n' "$line2"
fi

# Blank separator
printf '\n'

# --- Progress row helper ---
# Usage: print_row <label_plain> <label_width> <pct> <right_text_plain>
# label_plain: plain text label (no escapes), padded to label_width with spaces
print_row() {
    local label="$1"
    local lw="$2"
    local pct="$3"
    local right="$4"

    # Pad label
    local padded
    padded=$(printf "%-${lw}s" "$label")

    # Bar (width from global $bar_width, responsive to terminal width)
    local bar; bar=$(render_bar "$pct")
    local bar_color; bar_color=$(usage_color "$pct")

    # Percent, right-aligned in 4 chars (e.g. " 8%", "87%")
    local pct_str; pct_str=$(printf "%3d%%" "$pct")

    # Tighter spacing: 1 space after bar, 2 spaces before right text
    printf '%b\n' "${white}${padded}${reset}  ${bar_color}${bar}${reset} ${bar_color}${pct_str}${reset}  ${dim}${right}${reset}"
}

# Label width: "Chat context" = 12, "Plan · 5-hour" = 13, "Plan · weekly" = 13 → use 13
LW=13

# --- Chat context row ---
ctx_right="${ctx_used_fmt} / ${ctx_size_fmt} tokens"
print_row "Chat context" "$LW" "$ctx_pct" "$ctx_right"

# --- Plan · 5-hour row ---
if [ -n "$fh_pct" ]; then
    fh_right=""
    if [ -n "$fh_rst_ep" ]; then
        fh_rel=$(relative_time "$fh_rst_ep")
        if [ "$fh_rel" = "now" ]; then
            fh_right="resets now"
        else
            fh_right="resets in ${fh_rel}"
        fi
    fi
    print_row "Plan · 5-hour" "$LW" "$fh_pct" "$fh_right"
else
    printf '%b\n' "${white}$(printf "%-${LW}s" "Plan · 5-hour")${reset}  ${dim}—${reset}"
fi

# --- Plan · weekly row ---
if [ -n "$sd_pct" ]; then
    sd_right=""
    if [ -n "$sd_rst_ep" ]; then
        sd_rel=$(relative_time "$sd_rst_ep")
        if [ "$sd_rel" = "now" ]; then
            sd_right="resets now"
        else
            sd_right="resets in ${sd_rel}"
        fi
    fi
    print_row "Plan · weekly" "$LW" "$sd_pct" "$sd_right"
else
    printf '%b\n' "${white}$(printf "%-${LW}s" "Plan · weekly")${reset}  ${dim}—${reset}"
fi

exit 0
