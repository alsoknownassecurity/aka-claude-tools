#!/usr/bin/env bash
# harness-pointer.sh — PreToolUse hook for the Bash tool.
#
# Points the harness in the right direction. When the agent reaches for a command
# that's wrong for THIS environment, intercept it and hand back a hint that steers
# it to the correct approach — instead of letting it run a command that fails
# confusingly, isn't installed, or is the wrong tool for your setup.
#
# Mechanism: it blocks the command (exit 2) and returns your hint. The block is
# the lever; the hint is the point. This is GUIDANCE, not a security boundary — it
# matches only the first word, so `sudo <cmd>` / pipes slip past. Real restrictions
# belong in settings.json permissions.deny.
#
# Ships DISABLED and with an EMPTY list — most engineers want every CLI. Opt in via
# aka-claude-tools.config (canonical example: self-hosted VCS, point `gh` users to git):
#
#     CT_BLOCKED_CMDS="gh|kubectl"
#     CT_BLOCKED_HINT="Use plain git — this team's remote is self-hosted, not GitHub."
#
# With CT_BLOCKED_CMDS empty (the default), this hook is a no-op.

set -euo pipefail

input="$(cat)"
cmd="$(jq -r '.tool_input.command // empty' <<<"$input" 2>/dev/null || true)"
[ -z "$cmd" ] && exit 0

# ── Load opt-in org config ──
_cfg="${CLAUDETOOLS_CONFIG:-}"
if [ -z "$_cfg" ]; then
    for c in "${CLAUDE_CONFIG_DIR:-}/aka-claude-tools.config" "$HOME/.claude/aka-claude-tools.config"; do
        [ -n "${c%/aka-claude-tools.config}" ] && [ -f "$c" ] && { _cfg="$c"; break; }
    done
fi
CT_BLOCKED_CMDS=""
CT_BLOCKED_HINT="This command isn't the right tool here (aka-claude-tools harness-pointer). Check aka-claude-tools.config for the intended approach."
# shellcheck disable=SC1090
[ -n "$_cfg" ] && [ -f "$_cfg" ] && source "$_cfg" 2>/dev/null || true

[ -z "$CT_BLOCKED_CMDS" ] && exit 0

# Match the first word of the (trimmed) first line of the command.
first_word="$(printf '%s' "$cmd" | head -1 | sed -E 's/^[[:space:]]+//' | awk '{print $1}')"
if printf '%s' "$first_word" | grep -qE "^(${CT_BLOCKED_CMDS})$"; then
    printf 'blocked: `%s` is disallowed in this environment.\n%s\n' "$first_word" "$CT_BLOCKED_HINT" >&2
    exit 2
fi

exit 0
