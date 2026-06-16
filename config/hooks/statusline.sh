#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# aka-claude-tools status line — design-first, AKA-branded. Width-responsive:
#   nano (<35) · micro (35-54) · mini (55-79) · normal (80+)
# Normal layout (boxed card, 3 lines; dim │ between major segments; segments
# in [brackets] are conditional and only appear when CC provides the data):
#   ╭ AKA ▸ repo/branch [✎dirty ↑a ↓b ⊡stash ⎇worktree] [│ PR#n ✓] │ model [effort]
#   │ CTX <gauge> % │ 5H % ↻reset │ WK % ↻reset [│ +credits] [│ +added −removed]
#   ╰ <time>  <weather>  <region> [│ SESSION SUMMARY]
#     (clock + temp localized by geolocation; region is the abbreviated
#     state/region code — coarser than city, so less wrong when IP geolocation
#     misses, and pinnable via preferences.location; session summary is CC's
#     session_name, uppercased + truncated to the terminal width)
# Distinct from the original: AKA green leads, ▰▱ block gauges (not the
# ⛁ buckets), uppercase letter-spaced labels, no full-width rules.
# Resolves its config dir from $CLAUDE_CONFIG_DIR so it works in any isolated
# config folder created by the aka-claude-tools installer (defaults to ~/.claude).
# ═══════════════════════════════════════════════════════════════════════════════

set -o pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

# Active config dir: honor CLAUDE_CONFIG_DIR (set by the `aka`-style alias),
# fall back to the default ~/.claude.
CFG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS_FILE="${CFG_DIR}/settings.json"

# Secure per-user cache dir. We `source` some of these files (settings cache,
# parallel-prefetch fragments) and interpolate others into sourced shell, so a
# world-writable, predictably-named path under /tmp is a local code-exec vector
# on shared hosts/CI: an attacker pre-creates the file with a fresh mtime and we
# run it as the user on the next refresh. Prefer a per-user base ($XDG_RUNTIME_DIR
# on systemd Linux, $TMPDIR on macOS — both already 0700 and per-user) over bare
# /tmp, create the dir 0700, and if it isn't owned by us (someone pre-created it)
# fall back to a private mktemp dir so we never read attacker-controlled files.
_CACHE_BASE="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
CACHE_DIR="${_CACHE_BASE%/}/aka-claude-tools-${USER:-anon}"
if ! mkdir -p "$CACHE_DIR" 2>/dev/null || [ ! -O "$CACHE_DIR" ]; then
    CACHE_DIR="$(mktemp -d 2>/dev/null)" || CACHE_DIR="/tmp"
fi
chmod 700 "$CACHE_DIR" 2>/dev/null || true

# Per-config cache key so multiple config folders don't collide.
_CFG_KEY="$(printf '%s' "$CFG_DIR" | tr -c 'A-Za-z0-9' '_')"
LOCATION_CACHE="${CACHE_DIR}/location-${_CFG_KEY}.json"
WEATHER_CACHE="${CACHE_DIR}/weather-${_CFG_KEY}.txt"
USAGE_CACHE="${CACHE_DIR}/usage-${_CFG_KEY}.json"
_SETTINGS_CACHE="${CACHE_DIR}/settings-${_CFG_KEY}.sh"

LOCATION_CACHE_TTL=3600
WEATHER_CACHE_TTL=900
USAGE_CACHE_TTL=900

# Cache settings.json parsing — only read TEMP_UNIT and USER_TZ
if [ -f "$_SETTINGS_CACHE" ] && [ -f "$SETTINGS_FILE" ] && [ "$SETTINGS_FILE" -ot "$_SETTINGS_CACHE" ]; then
    # shellcheck disable=SC1090
    source "$_SETTINGS_CACHE"
else
    jq -r '
      "TEMP_UNIT=" + (.preferences.temperatureUnit // "" | @sh) + "\n" +
      "USER_TZ=" + (.preferences.timezone // .principal.timezone // "UTC" | @sh)
    ' "$SETTINGS_FILE" 2>/dev/null > "$_SETTINGS_CACHE"
    # shellcheck disable=SC1090
    source "$_SETTINGS_CACHE" 2>/dev/null
fi
# TEMP_UNIT left empty here when the user hasn't set one — it's derived from the
# geolocated country later (Celsius worldwide except the few imperial holdouts).
case "${TEMP_UNIT:-}" in celsius|fahrenheit) ;; *) TEMP_UNIT="" ;; esac
USER_TZ="${USER_TZ:-UTC}"
# Fallback: inherit timezone from the default ~/.claude/settings.json when this
# config has none (harmless if absent).
if [ "$USER_TZ" = "UTC" ] && [ -f "$HOME/.claude/settings.json" ]; then
    _fallback_tz=$(jq -r '.principal.timezone // .preferences.timezone // empty' "$HOME/.claude/settings.json" 2>/dev/null)
    [ -n "$_fallback_tz" ] && USER_TZ="$_fallback_tz"
fi
# Still no explicit zone → use the machine's local timezone (not UTC), so the
# usage-reset window matches the user's region anywhere in the world.
if [ "$USER_TZ" = "UTC" ]; then
    _sys_tz="${TZ:-}"
    [ -z "$_sys_tz" ] && [ -L /etc/localtime ] && _sys_tz=$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')
    [ -n "$_sys_tz" ] && USER_TZ="$_sys_tz"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PARSE INPUT (must happen before parallel block consumes stdin)
# ─────────────────────────────────────────────────────────────────────────────

input=$(cat)

eval "$(jq -r '
  "current_dir=" + (.workspace.current_dir // .cwd // "." | @sh) + "\n" +
  "session_id=" + (.session_id // "" | @sh) + "\n" +
  "session_name=" + (.session_name // "" | @sh) + "\n" +
  "model_name=" + ((.model.display_name // .model.id // .model // "unknown") | if type=="string" then . else "unknown" end | @sh) + "\n" +
  "model_id=" + (.model.id // "" | @sh) + "\n" +
  "cc_version_json=" + (.version // "" | @sh) + "\n" +
  "context_max=" + (.context_window.context_window_size // 200000 | tostring) + "\n" +
  "context_pct=" + (.context_window.used_percentage // 0 | tostring) + "\n" +
  "total_input=" + (.context_window.total_input_tokens // 0 | tostring) + "\n" +
  "has_native_rate_limits=" + ((.rate_limits != null) | tostring) + "\n" +
  "native_usage_5h=" + (.rate_limits.five_hour.used_percentage // .rate_limits.five_hour.utilization // 0 | tostring) + "\n" +
  "native_usage_5h_reset=" + (.rate_limits.five_hour.resets_at // "" | @sh) + "\n" +
  "native_usage_7d=" + (.rate_limits.seven_day.used_percentage // .rate_limits.seven_day.utilization // 0 | tostring) + "\n" +
  "native_usage_7d_reset=" + (.rate_limits.seven_day.resets_at // "" | @sh) + "\n" +
  "native_usage_extra_enabled=" + (.rate_limits.extra_usage.is_enabled // false | tostring) + "\n" +
  "native_usage_extra_limit=" + (.rate_limits.extra_usage.monthly_limit // 0 | tostring) + "\n" +
  "native_usage_extra_used=" + (.rate_limits.extra_usage.used_credits // 0 | tostring) + "\n" +
  "pr_number=" + (.pr.number // "" | tostring | @sh) + "\n" +
  "pr_state=" + (.pr.review_state // "" | @sh) + "\n" +
  "wt_name=" + (.workspace.git_worktree // .worktree.name // "" | @sh) + "\n" +
  "effort_level=" + (.effort.level // "" | @sh) + "\n" +
  "lines_added=" + (.cost.total_lines_added // 0 | tostring) + "\n" +
  "lines_removed=" + (.cost.total_lines_removed // 0 | tostring)
' 2>/dev/null <<< "$input")"

context_pct=${context_pct:-0}
context_max=${context_max:-200000}
total_input=${total_input:-0}
has_native_rate_limits="${has_native_rate_limits:-false}"

# CC version: prefer JSON input, fall back to cached claude --version output
_CC_VERSION_CACHE="${CACHE_DIR}/version.txt"
if [ -n "$cc_version_json" ] && [ "$cc_version_json" != "unknown" ]; then
    cc_version="$cc_version_json"
elif [ -f "$_CC_VERSION_CACHE" ] && [ -z "$(find "$_CC_VERSION_CACHE" -mtime +1 2>/dev/null)" ]; then
    cc_version=$(cat "$_CC_VERSION_CACHE" 2>/dev/null)
fi
if [ -z "$cc_version" ] || [ "$cc_version" = "unknown" ]; then
    cc_version=$(claude --version 2>/dev/null | head -1 | awk '{print $1}')
    cc_version="${cc_version:-?}"
    [ "$cc_version" != "?" ] && echo "$cc_version" > "$_CC_VERSION_CACHE" 2>/dev/null
fi

# Model name: derive from the AUTHORITATIVE .model.id (e.g. claude-fable-5 →
# "Fable 5"), not .model.display_name. Claude Code's display_name is a generic
# family label that can mislabel a newer tier — a Fable 5 session reports
# display_name "Opus"/"Opus 4.8" because Fable shares Opus's underlying model.
# .model.id carries the true identifier. Fall back to display_name when the id is
# absent or an unrecognized shape.
model_short=""
if [ -n "${model_id:-}" ] && [ "${model_id}" != "${model_id#claude-}" ]; then
    _mid="${model_id#claude-}"          # fable-5 | opus-4-8 | sonnet-4-6-20990101
    _fam="${_mid%%-*}"                   # fable | opus | sonnet
    _ver="${_mid#*-}"                    # 5 | 4-8 | 4-6-20990101
    if [ "$_ver" != "$_mid" ]; then      # a version segment was present
        _ver=$(printf '%s' "$_ver" | sed -E 's/-[0-9]{8}$//' | tr '-' '.')  # drop date snapshot, dot the version
        case "$_fam" in
            opus|sonnet|haiku|fable|mythos)
                _fam_cap=$(printf '%s' "$_fam" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')
                model_short="${_fam_cap} ${_ver}" ;;
        esac
    fi
fi
# Fallback: strip a leading "Claude " from the display name (older ids / unknown families).
[ -z "$model_short" ] && model_short=$(printf '%s' "$model_name" | sed 's/^[Cc]laude[- ]//; s/^$/Claude/')

dir_name=$(basename "$current_dir" 2>/dev/null || echo ".")

# Escape % → %% in values that get embedded in a printf FORMAT string below
# (git/identity segments use `printf "${COLOR}${value}${RESET}"` to interpret the
# \033 color escapes, so a literal % in the value would be read as a format spec).
# A branch like 'feat/100%s' or a dir named '50%done' otherwise renders corrupted.
# Ambient-line values (time/weather/region/session) are NOT escaped here — they go
# out via `printf '%b' "$arg"`, where the value is an argument, not the format.
model_short="${model_short//%/%%}"
dir_name="${dir_name//%/%%}"

# Session display: use CC-native session_name if set
session_display=""
if [ -n "$session_name" ]; then
    session_display=$(echo "$session_name" | tr '[:lower:]' '[:upper:]')
fi

# ─────────────────────────────────────────────────────────────────────────────
# TERMINAL WIDTH DETECTION
# ─────────────────────────────────────────────────────────────────────────────

_width_cache="${CACHE_DIR}/width-${KITTY_WINDOW_ID:-default}"

detect_terminal_width() {
    # Claude Code sets COLUMNS for the statusline process, and tput/stty are
    # documented as unreliable inside it (no controlling tty) — so COLUMNS is
    # authoritative. The rest is fallback for running outside CC.
    if [ -n "${COLUMNS:-}" ] && [ "$COLUMNS" -gt 0 ] 2>/dev/null; then
        echo "$COLUMNS" > "$_width_cache" 2>/dev/null
        echo "$COLUMNS"; return
    fi
    local width=""
    if [ -n "$KITTY_WINDOW_ID" ] && command -v kitten >/dev/null 2>&1; then
        width=$(kitten @ ls 2>/dev/null | jq -r --argjson wid "$KITTY_WINDOW_ID" \
            '.[].tabs[].windows[] | select(.id == $wid) | .columns' 2>/dev/null)
    fi
    [ -z "$width" ] || [ "$width" = "0" ] || [ "$width" = "null" ] && \
        width=$({ stty size </dev/tty; } 2>/dev/null | awk '{print $2}')
    [ -z "$width" ] || [ "$width" = "0" ] && width=$(tput cols 2>/dev/null)
    if [ -n "$width" ] && [ "$width" != "0" ] && [ "$width" -gt 0 ] 2>/dev/null; then
        echo "$width" > "$_width_cache" 2>/dev/null
        echo "$width"; return
    fi
    if [ -f "$_width_cache" ]; then
        local cached; cached=$(cat "$_width_cache" 2>/dev/null)
        [ "$cached" -gt 0 ] 2>/dev/null && echo "$cached" && return
    fi
    echo "80"
}

term_width=$(detect_terminal_width)
[ -z "$term_width" ] || [ "$term_width" -le 0 ] 2>/dev/null && term_width=80

if   [ "$term_width" -lt 35 ]; then MODE="nano"
elif [ "$term_width" -lt 55 ]; then MODE="micro"
elif [ "$term_width" -lt 80 ]; then MODE="mini"
else                                 MODE="normal"
fi


# ─────────────────────────────────────────────────────────────────────────────
# DATE HELPERS
# ─────────────────────────────────────────────────────────────────────────────

if date --version >/dev/null 2>&1; then DATE_FLAVOR="gnu"; else DATE_FLAVOR="bsd"; fi

if _stat_probe=$(stat -f %m "$0" 2>/dev/null) && [[ "$_stat_probe" =~ ^[0-9]+$ ]]; then
    STAT_FLAVOR="bsd"
else
    STAT_FLAVOR="gnu"
fi
unset _stat_probe

get_mtime() {
    if [ "$STAT_FLAVOR" = "bsd" ]; then stat -f %m "$1" 2>/dev/null || echo 0
    else                                stat -c %Y "$1" 2>/dev/null || echo 0
    fi
}

parse_iso_epoch() {
    local ts="$1"
    [ -z "$ts" ] && echo 0 && return
    if [[ "$ts" =~ ^[0-9]+$ ]]; then echo "$ts"; return; fi
    local clean="$ts"
    if [[ "$clean" =~ ^(.*)\.[0-9]+(Z|[+-][0-9][0-9]:[0-9][0-9])$ ]]; then
        clean="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
    elif [[ "$clean" =~ ^(.*)\.[0-9]+$ ]]; then
        clean="${BASH_REMATCH[1]}"
    fi
    if [[ "$clean" =~ ^(.*)([+-][0-9][0-9]):([0-9][0-9])$ ]]; then
        clean="${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
    elif [[ "$clean" =~ Z$ ]]; then
        clean="${clean%Z}+0000"
    else
        clean="${clean}+0000"
    fi
    if [ "$DATE_FLAVOR" = "gnu" ]; then
        date -d "$ts" +%s 2>/dev/null || echo 0
    else
        date -jf "%Y-%m-%dT%H:%M:%S%z" "$clean" +%s 2>/dev/null || echo 0
    fi
}

# Reset clock follows the same locale rule as the ambient clock (AM/PM for
# US-style geolocated countries, else 24h). Always "DOW time" — including
# today — so the format never shifts shape as a reset approaches midnight.
reset_time_str() {
    local epoch="$1"
    [ -z "$epoch" ] || [ "$epoch" -le 0 ] 2>/dev/null && echo "now" && return
    local now_epoch="${NOW_EPOCH:-$(date +%s)}"
    [ "$epoch" -le "$now_epoch" ] 2>/dev/null && echo "now" && return
    local tfmt="%H:%M"
    case "${location_cc:-}" in
        US|LR|KY|BS|BZ|PW|FM|MH|GU|VI|PR|AS) tfmt="%l:%M%p" ;;
    esac
    local reset_dow reset_time dow
    # Time last: %l pads single-digit hours with a space, which `read` trims.
    if [ "$DATE_FLAVOR" = "gnu" ]; then
        read -r reset_dow reset_time <<< "$(TZ="$USER_TZ" date -d "@$epoch" "+%w ${tfmt}")"
    else
        read -r reset_dow reset_time <<< "$(TZ="$USER_TZ" date -r "$epoch" "+%w ${tfmt}")"
    fi
    case "$reset_dow" in
        0) dow="SUN" ;; 1) dow="MON" ;; 2) dow="TUE" ;; 3) dow="WED" ;;
        4) dow="THU" ;; 5) dow="FRI" ;; 6) dow="SAT" ;; *) dow="" ;;
    esac
    echo "${dow:+$dow }${reset_time}"
}

# ─────────────────────────────────────────────────────────────────────────────
# PARALLEL PREFETCH
# ─────────────────────────────────────────────────────────────────────────────

# Exclusively-created, unpredictably-named per-run dir: its fragments are sourced,
# so it must never be a path an attacker can pre-create (see CACHE_DIR rationale).
_parallel_tmp="$(mktemp -d "${CACHE_DIR}/parallel.XXXXXX" 2>/dev/null)" || _parallel_tmp="$(mktemp -d)"
NOW_EPOCH=$(date +%s)

# 1. Git
{
    if git rev-parse --git-dir > /dev/null 2>&1; then
        branch=$(git branch --show-current 2>/dev/null)
        [ -z "$branch" ] && branch="detached"
        # Repo name: from the origin remote (the canonical name), else the
        # working-tree folder name.
        _remote_url=$(git config --get remote.origin.url 2>/dev/null)
        if [ -n "$_remote_url" ]; then repo=$(basename -s .git "$_remote_url" 2>/dev/null)
        else repo=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null); fi
        [ -z "$repo" ] && repo="?"
        stash_count=$(git stash list 2>/dev/null | wc -l | tr -d ' ')
        [ -z "$stash_count" ] && stash_count=0
        dirty=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        [ -z "$dirty" ] && dirty=0
        sync_info=$(git rev-list --left-right --count HEAD...@{u} 2>/dev/null)
        last_commit_epoch=$(git log -1 --format='%ct' 2>/dev/null)
        if [ -n "$sync_info" ]; then read -r ahead behind <<< "$sync_info"
        else ahead=0; behind=0; fi
        [ -z "$ahead" ] && ahead=0; [ -z "$behind" ] && behind=0
        cat > "$_parallel_tmp/git.sh" << GITEOF
branch='$branch'
repo='$repo'
stash_count=${stash_count:-0}
dirty=${dirty:-0}
ahead=${ahead:-0}
behind=${behind:-0}
last_commit_epoch=${last_commit_epoch:-0}
is_git_repo=true
GITEOF
    else
        echo "is_git_repo=false" > "$_parallel_tmp/git.sh"
    fi
} &

if [ "$MODE" = "mini" ] || [ "$MODE" = "normal" ]; then
{
    # 2. Location fetch (with caching)
    # Pinned location from settings (opt-in at install): exact, VPN-proof, no IP
    # lookup. Re-applied if the /tmp cache was cleared (e.g. after a reboot).
    _pin=$(jq -c '.preferences.location // empty' "$SETTINGS_FILE" 2>/dev/null)
    if [ -n "$_pin" ] && echo "$_pin" | jq -e '(.latitude != null) and (.longitude != null)' >/dev/null 2>&1; then
        if [ ! -f "$LOCATION_CACHE" ] || ! jq -e '.pinned == true' "$LOCATION_CACHE" >/dev/null 2>&1; then
            echo "$_pin" | jq '{latitude, longitude, country_code:(.countryCode // ""), region_code:(.regionCode // ""), city:(.city // ""), success:true, pinned:true}' > "$LOCATION_CACHE"
        fi
    fi
    cache_age=999999
    [ -f "$LOCATION_CACHE" ] && cache_age=$((NOW_EPOCH - $(get_mtime "$LOCATION_CACHE")))
    _loc_pinned=false
    [ -f "$LOCATION_CACHE" ] && _loc_pinned=$(jq -r '.pinned // false' "$LOCATION_CACHE" 2>/dev/null)
    if [ "$_loc_pinned" != "true" ] && [ "$cache_age" -gt "$LOCATION_CACHE_TTL" ]; then
        # ipwho.is — HTTPS, free, no API key (avoids the plaintext IP query that
        # ip-api.com's free tier forces over HTTP).
        loc_data=$(curl -s --max-time 3 "https://ipwho.is/" 2>/dev/null)
        if [ -n "$loc_data" ] && echo "$loc_data" | jq -e '.success == true' >/dev/null 2>&1; then
            echo "$loc_data" > "$LOCATION_CACHE"
        fi
    fi
    cc_to_flag() {
        local code="${1:-}"
        [ "${#code}" -ne 2 ] && { printf '🌐'; return; }
        local c1 c2 b1 b2
        c1=$(printf '%d' "'${code:0:1}")
        c2=$(printf '%d' "'${code:1:1}")
        [ "$c1" -lt 65 ] || [ "$c1" -gt 90 ] || [ "$c2" -lt 65 ] || [ "$c2" -gt 90 ] && { printf '🌐'; return; }
        b1=$(printf '%02x' $((0xA6 + c1 - 65)))
        b2=$(printf '%02x' $((0xA6 + c2 - 65)))
        printf "\xF0\x9F\x87\x${b1}\xF0\x9F\x87\x${b2}"
    }
    if [ -f "$LOCATION_CACHE" ]; then
        eval "$(jq -r '
            "_lc_city=" + (.city // "" | @sh) + "\n" +
            "_lc_region=" + (.region_code // "" | @sh) + "\n" +
            "_lc_cc=" + (.country_code // "" | @sh)
        ' "$LOCATION_CACHE" 2>/dev/null)"
        _lc_flag=$(cc_to_flag "$_lc_cc")
        {
            printf "location_city=%q\n" "$(printf '%s' "$_lc_city" | tr '[:lower:]' '[:upper:]')"
            printf "location_region=%q\n" "$(printf '%s' "$_lc_region" | tr '[:lower:]' '[:upper:]')"
            printf "location_cc=%q\n" "$(printf '%s' "$_lc_cc" | tr '[:lower:]' '[:upper:]')"
            printf "location_flag=%q\n" "$_lc_flag"
        } > "$_parallel_tmp/location.sh"
    else
        echo -e "location_city='UNKNOWN'\nlocation_region=''\nlocation_cc=''\nlocation_flag='🌐'" > "$_parallel_tmp/location.sh"
    fi
} &
fi

if [ "$MODE" = "mini" ] || [ "$MODE" = "normal" ]; then
{
    # 3. Weather fetch (with caching)
    cache_age=999999
    [ -f "$WEATHER_CACHE" ] && cache_age=$((NOW_EPOCH - $(get_mtime "$WEATHER_CACHE")))
    if [ "$cache_age" -gt "$WEATHER_CACHE_TTL" ]; then
        lat="" lon=""
        if [ -f "$LOCATION_CACHE" ]; then
            # @sh-quote the geocoder values before eval — they originate from a
            # remote API (ipwho.is); a compromised/MITM'd response must not inject.
            eval "$(jq -r '"lat=\(.latitude // empty | @sh)\nlon=\(.longitude // empty | @sh)"' "$LOCATION_CACHE" 2>/dev/null)"
        fi
        # No fabricated default location — only fetch when we actually know where
        # the user is, so the temperature reflects THEIR location (or shows "—").
        if [ -n "$lat" ] && [ -n "$lon" ]; then
            # Derive the unit from the geolocated country when the user hasn't set one:
            # Celsius everywhere except the handful of Fahrenheit holdouts.
            if [ -z "$TEMP_UNIT" ]; then
                _wcc=$(jq -r '.country_code // ""' "$LOCATION_CACHE" 2>/dev/null)
                case "$_wcc" in
                    US|LR|KY|BS|BZ|PW|FM|MH|GU|VI|PR|AS) TEMP_UNIT="fahrenheit" ;;
                    *) TEMP_UNIT="celsius" ;;
                esac
            fi
            weather_json=$(curl -s --max-time 3 "https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lon}&current=temperature_2m,weather_code,is_day&temperature_unit=${TEMP_UNIT}" 2>/dev/null)
            if [ -n "$weather_json" ] && echo "$weather_json" | jq -e '.current' >/dev/null 2>&1; then
                # @sh-quote remote API values (open-meteo.com) before eval.
                eval "$(echo "$weather_json" | jq -r '.current | "temp=\(.temperature_2m | @sh)\ncode=\(.weather_code | @sh)\nis_day=\(.is_day | @sh)"' 2>/dev/null)"
                case "$code" in
                    0)              [ "${is_day:-1}" = "0" ] && icon="🌙" || icon="☀️" ;;
                    1)              [ "${is_day:-1}" = "0" ] && icon="🌙" || icon="🌤️" ;;
                    2)              icon="⛅" ;; 3) icon="☁️" ;;
                    45|48)          icon="🌫️" ;;
                    51|53|55|56|57) icon="🌦️" ;;
                    61|63|65|66|67) icon="🌧️" ;;
                    80|81|82)       icon="🌧️" ;;
                    71|73|75|77|85|86) icon="🌨️" ;;
                    95|96|99)       icon="⛈️" ;;
                    *)              icon="🌡️" ;;
                esac
                temp_int=$(printf '%.0f' "$temp")
                if [ "$TEMP_UNIT" = "celsius" ]; then
                    echo "${icon} ${temp_int}°C" > "$WEATHER_CACHE"
                else
                    echo "${icon} ${temp_int}°F" > "$WEATHER_CACHE"
                fi
            fi
        fi
    fi
    if [ -f "$WEATHER_CACHE" ]; then
        echo "weather_str='$(cat "$WEATHER_CACHE" 2>/dev/null)'" > "$_parallel_tmp/weather.sh"
    else
        echo "weather_str='—'" > "$_parallel_tmp/weather.sh"
    fi
} &
fi

if [ "$MODE" = "normal" ]; then
{
    # 4. Usage data — prefer native rate_limits from CC JSON, fall back to OAuth API
    _usage_now=$NOW_EPOCH
    if [ "$has_native_rate_limits" = "true" ]; then
        cat > "$_parallel_tmp/usage.sh" << USAGEEOF
usage_5h=${native_usage_5h:-0}
usage_5h_reset=${native_usage_5h_reset:-''}
usage_7d=${native_usage_7d:-0}
usage_7d_reset=${native_usage_7d_reset:-''}
usage_extra_enabled=${native_usage_extra_enabled:-false}
usage_extra_limit=${native_usage_extra_limit:-0}
usage_extra_used=${native_usage_extra_used:-0}
USAGEEOF
    else
        cache_age=999999
        [ -f "$USAGE_CACHE" ] && cache_age=$((_usage_now - $(get_mtime "$USAGE_CACHE")))
        if [ "$cache_age" -gt "$USAGE_CACHE_TTL" ]; then
            if [ "$(uname -s)" = "Darwin" ]; then
                cred_json=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
            else
                cred_json=$(cat "${CFG_DIR}/.credentials.json" 2>/dev/null || cat "${HOME}/.claude/.credentials.json" 2>/dev/null)
            fi
            token=$(echo "$cred_json" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
            if [ -n "$token" ]; then
                usage_json=$(curl -s --max-time 3 \
                    -H "Authorization: Bearer $token" \
                    -H "Content-Type: application/json" \
                    -H "anthropic-beta: oauth-2025-04-20" \
                    "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
                if [ -n "$usage_json" ] && echo "$usage_json" | jq -e '.five_hour' >/dev/null 2>&1; then
                    echo "$usage_json" | jq '.' > "$USAGE_CACHE" 2>/dev/null
                fi
            fi
        fi
        _usage_age=999999
        [ -f "$USAGE_CACHE" ] && _usage_age=$((_usage_now - $(get_mtime "$USAGE_CACHE")))
        if [ -f "$USAGE_CACHE" ] && [ "$_usage_age" -lt 1800 ]; then
            jq -r '
                "usage_5h=" + (.five_hour.utilization // 0 | tostring) + "\n" +
                "usage_5h_reset=" + (.five_hour.resets_at // "" | @sh) + "\n" +
                "usage_7d=" + (.seven_day.utilization // 0 | tostring) + "\n" +
                "usage_7d_reset=" + (.seven_day.resets_at // "" | @sh) + "\n" +
                "usage_extra_enabled=" + (.extra_usage.is_enabled // false | tostring) + "\n" +
                "usage_extra_limit=" + (.extra_usage.monthly_limit // 0 | tostring) + "\n" +
                "usage_extra_used=" + (.extra_usage.used_credits // 0 | tostring)
            ' "$USAGE_CACHE" > "$_parallel_tmp/usage.sh" 2>/dev/null
        else
            rm -f "$USAGE_CACHE" 2>/dev/null
            echo -e "usage_5h=0\nusage_7d=0\nusage_extra_enabled=false\nusage_no_data=true" > "$_parallel_tmp/usage.sh"
        fi
    fi
} &
fi

wait

[ -f "$_parallel_tmp/git.sh" ]      && source "$_parallel_tmp/git.sh"
[ -f "$_parallel_tmp/location.sh" ] && source "$_parallel_tmp/location.sh"
[ -f "$_parallel_tmp/weather.sh" ]  && source "$_parallel_tmp/weather.sh"
[ -f "$_parallel_tmp/usage.sh" ]    && source "$_parallel_tmp/usage.sh"
rm -rf "$_parallel_tmp" 2>/dev/null

# Escape % in git-derived identity values for the same printf-format reason as
# model_short/dir_name above (repo/branch/worktree names may legally contain %).
repo="${repo:-}";       repo="${repo//%/%%}"
branch="${branch:-}";   branch="${branch//%/%%}"
wt_name="${wt_name:-}"; wt_name="${wt_name//%/%%}"

# Compute git age once — shared by all modes
_git_age=""
if [ "$is_git_repo" = "true" ] && [ -n "$last_commit_epoch" ] && [ "$last_commit_epoch" -gt 0 ] 2>/dev/null; then
    _age_s=$((NOW_EPOCH - last_commit_epoch))
    _age_m=$((_age_s / 60)); _age_h=$((_age_s / 3600)); _age_d=$((_age_s / 86400))
    if   [ "$_age_m" -lt 1 ];  then _git_age="now"
    elif [ "$_age_h" -lt 1 ];  then _git_age="${_age_m}m"
    elif [ "$_age_h" -lt 24 ]; then _git_age="${_age_h}h"
    else                            _git_age="${_age_d}d"
    fi
fi

# Supplement missing reset timestamps from cache when native rate_limits omits resets_at
if [ "$MODE" = "normal" ] && { [ -z "${usage_5h_reset:-}" ] || [ -z "${usage_7d_reset:-}" ]; } && [ -f "$USAGE_CACHE" ]; then
    eval "$(jq -r '
        "_cache_5h_reset=" + (.five_hour.resets_at // "" | @sh) + "\n" +
        "_cache_7d_reset=" + (.seven_day.resets_at // "" | @sh)
    ' "$USAGE_CACHE" 2>/dev/null)"
    [ -z "${usage_5h_reset:-}" ] && usage_5h_reset="${_cache_5h_reset:-}"
    [ -z "${usage_7d_reset:-}" ] && usage_7d_reset="${_cache_7d_reset:-}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PALETTE — AKA-inspired, tuned for dark terminals. The brand palette was made
# for a white page; here the AKA green (#00E0B8) leads and the neutrals are
# lifted so they read on black. 
# ─────────────────────────────────────────────────────────────────────────────

RESET='\033[0m'; BOLD='\033[1m'
AKA_GREEN='\033[38;2;0;224;184m'      # #00E0B8 — signature accent / brand mark
AKA_CYAN='\033[38;2;106;217;255m'     # #6AD9FF — branch, info
AKA_LAVENDER='\033[38;2;138;152;255m' # #8A98FF — model
AKA_TEXT='\033[38;2;195;208;222m'     # #C3D0DE — primary text on dark
AKA_MUTED='\033[38;2;154;170;187m'    # #9AAABB — ambient values
AKA_DIM='\033[38;2;107;125;143m'      # #6B7D8F — labels, separators
AKA_FAINT='\033[38;2;61;78;94m'       # #3D4E5E — empty gauge cells
SEV_GOOD='\033[38;2;0;224;184m'       # green   — healthy
SEV_WARN='\033[38;2;221;107;32m'      # #DD6B20 — filling up
SEV_HIGH='\033[38;2;247;111;104m'     # #F76F68 — danger

# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────

# level_color <pct> — severity color by fill level
level_color() {
    local p="${1%%.*}"; [ -z "$p" ] && p=0
    if   [ "$p" -ge 85 ] 2>/dev/null; then printf '%s' "$SEV_HIGH"
    elif [ "$p" -ge 60 ] 2>/dev/null; then printf '%s' "$SEV_WARN"
    else                                    printf '%s' "$SEV_GOOD"
    fi
}

# meter <width> <pct> — solid block gauge (▰ filled / ▱ empty), fill by level
meter() {
    local w="$1" p="${2%%.*}" col i out=""
    [ -z "$p" ] && p=0
    local filled=$(( (p * w + 50) / 100 ))
    # Any nonzero usage shows at least one block — an empty gauge next to "12%"
    # reads as broken.
    [ "$p" -gt 0 ] && [ "$filled" -lt 1 ] && filled=1
    [ "$filled" -gt "$w" ] && filled=$w
    [ "$filled" -lt 0 ] && filled=0
    col=$(level_color "$p")
    for ((i=1; i<=w; i++)); do
        if [ "$i" -le "$filled" ]; then out="${out}${col}▰${RESET}"
        else                            out="${out}${AKA_FAINT}▱${RESET}"; fi
    done
    printf '%s' "$out"
}

# Brand mark, card-frame edge, separator (dim │ between major segments;
# within a group: git-style repo/branch, double-spaces on the ambient line)
mark() { printf "${BOLD}${AKA_GREEN}AKA${RESET} ${AKA_DIM}▸${RESET} "; }
edge() { printf "${AKA_FAINT}%s${RESET} " "$1"; }
pipe() { printf " ${AKA_DIM}│${RESET} "; }

# repo/branch [✎dirty] [↑a ↓b] [⊡stash] [⎇worktree], or cwd when not a git repo
git_segment() {
    if [ "${is_git_repo:-false}" = "true" ]; then
        printf "${AKA_TEXT}${repo}${RESET}${AKA_DIM}/${RESET}${AKA_CYAN}${branch}${RESET}"
        [ "${dirty:-0}" -gt 0 ] 2>/dev/null && printf " ${SEV_WARN}✎${dirty}${RESET}"
        { [ "${ahead:-0}" -gt 0 ] || [ "${behind:-0}" -gt 0 ]; } 2>/dev/null \
            && printf " ${AKA_DIM}↑${ahead:-0} ↓${behind:-0}${RESET}"
        [ "${stash_count:-0}" -gt 0 ] 2>/dev/null && printf " ${AKA_DIM}⊡${stash_count}${RESET}"
        [ -n "${wt_name:-}" ] && printf " ${AKA_DIM}⎇${wt_name}${RESET}"
    else
        printf "${AKA_MUTED}${dir_name}${RESET}"
    fi
}

# │ PR#<n> <state-glyph> — only while an open PR exists for the branch (CC's
# native bar shows this badge; a custom statusline replaces that bar, so we
# carry it over).
pr_segment() {
    [ -z "${pr_number:-}" ] && return
    local badge=""
    case "${pr_state:-}" in
        approved)          badge=" ${SEV_GOOD}✓${RESET}" ;;
        changes_requested) badge=" ${SEV_HIGH}✗${RESET}" ;;
        pending)           badge=" ${SEV_WARN}○${RESET}" ;;
        draft)             badge=" ${AKA_DIM}◌${RESET}" ;;
    esac
    pipe; printf "${AKA_TEXT}PR#${pr_number}${RESET}${badge}"
}

# Localized clock: AM/PM for US-style locales (per geolocated country), else 24h.
case "${location_cc:-}" in
    US|LR|KY|BS|BZ|PW|FM|MH|GU|VI|PR|AS)
        current_time=$(TZ="$USER_TZ" date +"%I:%M %p" 2>/dev/null); current_time="${current_time#0}" ;;
    *)  current_time=$(TZ="$USER_TZ" date +"%H:%M" 2>/dev/null) ;;
esac

ctx_pct="${context_pct%%.*}"; [ -z "$ctx_pct" ] && ctx_pct=0
ctx_color=$(level_color "$ctx_pct")
dirty="${dirty:-0}"

# Effort suffix on the model — shown whenever the model reports one.
_effort=""
[ -n "${effort_level:-}" ] && _effort=" ${AKA_DIM}${effort_level//%/%%}${RESET}"

# ═══════════════════════════════════════════════════════════════════════════════
# COMPACT MODES (narrow terminals)
# ═══════════════════════════════════════════════════════════════════════════════

if [ "$MODE" != "normal" ]; then
    case "$MODE" in
        nano)
            printf "${BOLD}${AKA_GREEN}AKA${RESET} ${ctx_color}${ctx_pct}%%${RESET}\n"
            [ "${is_git_repo:-false}" = "true" ] && printf "${AKA_CYAN}${branch}${RESET}\n"
            ;;
        micro)
            printf "${BOLD}${AKA_GREEN}AKA${RESET} ${AKA_DIM}▸${RESET} ${ctx_color}${ctx_pct}%%${RESET}"
            pipe; printf "${AKA_LAVENDER}${model_short}${RESET}\n"
            if [ "${is_git_repo:-false}" = "true" ]; then
                printf "${AKA_CYAN}${branch}${RESET}"
                [ "${dirty:-0}" -gt 0 ] 2>/dev/null && printf " ${SEV_WARN}✎${dirty}${RESET}"
                printf "\n"
            fi
            ;;
        mini)
            edge "╭"; mark; git_segment; pipe; printf "${AKA_LAVENDER}${model_short}${RESET}${_effort}\n"
            edge "╰"; printf "${AKA_DIM}CTX${RESET} $(meter 10 "$ctx_pct") ${ctx_color}${ctx_pct}%%${RESET}\n"
            ;;
    esac
    exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════════
# NORMAL MODE — boxed card (identity · meters · ambient)
# ═══════════════════════════════════════════════════════════════════════════════

# Line 1 — identity:  ╭ AKA ▸ repo/branch [markers] [│ PR#n] │ model [effort]
edge "╭"; mark; git_segment; pr_segment; pipe; printf "${AKA_LAVENDER}${model_short}${RESET}${_effort}\n"

# Line 2 — meters:  │ CTX <gauge> % │ 5H % ↻reset │ WK % ↻reset │ [+credits]
edge "│"
printf "${AKA_DIM}CTX${RESET} $(meter 10 "$ctx_pct") ${ctx_color}${ctx_pct}%%${RESET}"
_u5="${usage_5h%%.*}"; [ -z "$_u5" ] && _u5=0
_u7="${usage_7d%%.*}"; [ -z "$_u7" ] && _u7=0
if [ "${usage_no_data:-false}" != "true" ] && { [ "$_u5" -gt 0 ] || [ "$_u7" -gt 0 ] || [ -f "$USAGE_CACHE" ]; } 2>/dev/null; then
    _r5=""; _e5=$(parse_iso_epoch "${usage_5h_reset:-}")
    [ "$_e5" -gt "$NOW_EPOCH" ] 2>/dev/null && _r5=" ${AKA_FAINT}↻$(reset_time_str "$_e5")${RESET}"
    _r7=""; _e7=$(parse_iso_epoch "${usage_7d_reset:-}")
    [ "$_e7" -gt "$NOW_EPOCH" ] 2>/dev/null && _r7=" ${AKA_FAINT}↻$(reset_time_str "$_e7")${RESET}"
    pipe; printf "${AKA_DIM}5H${RESET} $(level_color "$_u5")${_u5}%%${RESET}${_r5}"
    pipe; printf "${AKA_DIM}WK${RESET} $(level_color "$_u7")${_u7}%%${RESET}${_r7}"
    if [ "${usage_extra_enabled:-false}" = "true" ]; then
        _eu=$(( ${usage_extra_used%%.*} / 100 )); _el=$(( ${usage_extra_limit:-0} / 100 ))
        pipe; printf "${AKA_DIM}+\$${_eu}/\$${_el}${RESET}"
    fi
fi
# Session diff stat — what this session has actually changed.
if { [ "${lines_added:-0}" -gt 0 ] || [ "${lines_removed:-0}" -gt 0 ]; } 2>/dev/null; then
    pipe; printf "${SEV_GOOD}+${lines_added}${RESET} ${SEV_HIGH}−${lines_removed}${RESET}"
fi
printf "\n"

# Line 3 — ambient (dimmed, localized):  ╰ time  weather  region │ SESSION
# Region (abbreviated state, e.g. CA) rather than city: IP geolocation is often
# a metro off within the right region, so the coarser unit is the honest one.
# _amb_plain mirrors _amb without escapes so the session summary can be
# truncated to the real remaining width.
_amb=""; _amb_plain=""
if [ -n "$current_time" ]; then
    _amb="${AKA_MUTED}${current_time}${RESET}"
    _amb_plain="$current_time"
fi
if [ -n "${weather_str:-}" ] && [ "$weather_str" != "—" ]; then
    [ -n "$_amb" ] && { _amb="${_amb}  "; _amb_plain="${_amb_plain}  "; }
    _amb="${_amb}${AKA_MUTED}${weather_str}${RESET}"
    _amb_plain="${_amb_plain}${weather_str}"
fi
_loc="${location_region:-}"
[ -z "$_loc" ] && _loc="${location_city:-${location_cc:-}}"
if [ -n "$_loc" ] && [ "$_loc" != "UNKNOWN" ]; then
    [ -n "$_amb" ] && { _amb="${_amb}  "; _amb_plain="${_amb_plain}  "; }
    _amb="${_amb}${location_flag} ${AKA_MUTED}${_loc}${RESET}"
    _amb_plain="${_amb_plain}xx ${_loc}"   # flag ≈ 2 cols
fi
if [ -n "$session_display" ]; then
    _sess_avail=$(( term_width - 2 - ${#_amb_plain} - 3 ))
    if [ "$_sess_avail" -ge 8 ]; then
        [ "${#session_display}" -gt "$_sess_avail" ] && \
            session_display="${session_display:0:$((_sess_avail - 1))}…"
        [ -n "$_amb" ] && _amb="${_amb} ${AKA_DIM}│${RESET} "
        _amb="${_amb}${AKA_MUTED}${session_display}${RESET}"
    fi
fi
edge "╰"; printf '%b\n' "$_amb"

