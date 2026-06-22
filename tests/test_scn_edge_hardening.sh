#!/usr/bin/env bash
# Scenario — install.sh edge-hardening (the #30 tail). Pins three small robustness
# fixes so they can't silently regress:
#   A. Hook/statusLine command strings shell-QUOTE the config-dir portion, so a
#      config dir containing spaces/metachars doesn't word-split — and the command
#      still executes through a shell (as Claude Code runs hooks). The `/hooks/x`
#      suffix stays outside the quotes so basename matching still works.
#   B. merge_settings strips maintainer `"$comment"` keys RECURSIVELY from kit
#      payloads (not just top-level), so a nested note can't leak into the user's
#      settings.json — while the user's own keys are untouched.
#   C. alias_target_elsewhere / sourced_paths detect a QUOTED `source "…"` include,
#      not only the unquoted form (so an alias defined in a quoted-include file is
#      seen — no duplicate/shadow).
#
# Fully sandboxed: fake $HOME, never touches a real ~/.claude* or rc.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_edge_hardening:"

INSTALL="$REPO_ROOT/install.sh"

# ── A. command-string quoting survives a config dir with a space ─────────────
SB="$(sandbox)"; DIR="$SB/my configs/.claude-aka"   # deliberate space in the path
CT_CONFIG_DIR="$DIR" CT_ADDITIONS="secure-settings leak-guard statusline" HOME="$SB" \
  bash "$INSTALL" --apply --no-auth-inherit >"$SB/log" 2>&1
assert_eq "--apply exits 0 with a spaced config dir" "0" "$?"
S="$DIR/settings.json"
assert_ok "settings.json valid JSON" jq -e . "$S"
# Basename matching still works despite the embedded quotes.
assert_ok "leak-guard registration still matches by suffix" \
  bash -c "jq -e '[.hooks.PreToolUse[]?.hooks[].command]|any(endswith(\"/hooks/leak-guard.sh\"))' '$S' >/dev/null"
# The stored command shell-quotes the dir (so the space is safe).
assert_ok "command shell-quotes the config dir" \
  bash -c "jq -e '[.hooks.PreToolUse[]?.hooks[].command]|any(startswith(\"'\''\"))' '$S' >/dev/null"
# And it actually RUNS through a shell despite the space (leak-guard allows benign).
WGCMD="$(jq -r '[.hooks.PreToolUse[].hooks[].command]|map(select(test("leak-guard")))[0]' "$S")"
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | sh -c "$WGCMD" >/dev/null 2>&1
assert_eq "quoted leak-guard command executes through a shell (space-safe)" "0" "$?"
# statusLine command is quoted + suffix-matchable too.
assert_ok "statusLine command shell-quoted + suffix matches" \
  bash -c "jq -e '(.statusLine.command|startswith(\"'\''\")) and (.statusLine.command|endswith(\"/hooks/statusline.ts\"))' '$S' >/dev/null"

# ── B. nested \$comment never leaks; user keys preserved ─────────────────────
# merge_settings is a pure helper — reach it by sourcing install.sh in a subshell.
A_PAYLOAD='{"permissions":{"deny":["Read(x)"]},"$comment":["top note"],"hooks":{"PreToolUse":[{"matcher":"Bash","$comment":["nested note"],"hooks":[{"type":"command","command":"/k.sh"}]}]}}'
E_USER='{"theme":"dark","permissions":{"allow":["Bash(mine:*)"]}}'
MERGED="$( ( set -euo pipefail; source "$INSTALL" >/dev/null 2>&1; merge_settings "$E_USER" "$A_PAYLOAD" ) )"
assert_ok "merged output is valid JSON" bash -c "printf '%s' '$MERGED' | jq -e . >/dev/null"
assert_ok "NO \$comment anywhere in merged output (nested or top)" \
  bash -c "printf '%s' '$MERGED' | jq -e '[.. | objects | keys[]?]|index(\"\$comment\")|not' >/dev/null"
assert_ok "user's own key (theme) preserved" \
  bash -c "printf '%s' '$MERGED' | jq -e '.theme==\"dark\"' >/dev/null"
assert_ok "user's own allow rule preserved" \
  bash -c "printf '%s' '$MERGED' | jq -e '(.permissions.allow//[])|index(\"Bash(mine:*)\")!=null' >/dev/null"
assert_ok "kit deny adopted from the payload" \
  bash -c "printf '%s' '$MERGED' | jq -e '(.permissions.deny//[])|index(\"Read(x)\")!=null' >/dev/null"

# ── C. quoted source "…" include is detected ─────────────────────────────────
SB3="$(sandbox)"
INC="$SB3/aliases.sh"; printf 'alias work=%s\n' "'CLAUDE_CONFIG_DIR=\"$SB3/.claude-work\" claude'" > "$INC"
mkdir -p "$SB3/.claude-work"
RC="$SB3/.bashrc"; printf 'source "%s"\n' "$INC" > "$RC"   # QUOTED include
got="$( ( source "$REPO_ROOT/shared/lib/common.sh" >/dev/null 2>&1; sourced_paths "$RC" ) )"
assert_eq "sourced_paths resolves a quoted include" "$INC" "$got"
# End-to-end: the alias defined in the quoted-included file is found.
res="$( ( source "$REPO_ROOT/shared/lib/common.sh" >/dev/null 2>&1; alias_target_elsewhere work "$RC" ) )"
assert_eq "alias_target_elsewhere finds an alias in a quoted include" "$SB3/.claude-work" "$res"

t_summary
