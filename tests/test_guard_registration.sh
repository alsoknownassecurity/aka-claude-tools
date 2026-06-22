#!/usr/bin/env bash
# Guard registration shape — the egress guards must be wired into settings.json the
# way the design requires, or they silently don't fire:
#   - leak-guard registered ONCE: matcher "WebSearch|WebFetch" (WEB egress only). Bash
#     egress is command-guard's surface now — leak-guard must NOT be on Bash anymore.
#   - command-guard registered on "Bash" with an ABSOLUTE bun path (hook subshells
#     lack bun on PATH, so a bare shebang can silently fail to launch). Sole Bash guard.
#   - the shared lib/ (secret-patterns corpus) placed whenever a guard is selected.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_guard_registration:"

SB="$(sandbox)"; touch "$SB/.bashrc"
PROFILE="$SB/.claude-aka"
SHELL=/bin/bash HOME="$SB" bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log" 2>&1
S="$PROFILE/settings.json"

# leak-guard appears under exactly ONE registration: WebSearch|WebFetch (web-only).
assert_ok "leak-guard registered exactly once" \
  bash -c "jq -e '[.hooks.PreToolUse[] | select(.hooks[].command | endswith(\"/leak-guard.sh\"))] | length == 1' '$S' >/dev/null"
assert_ok "leak-guard registered under WebSearch|WebFetch only (NOT Bash)" \
  bash -c "jq -e '[.hooks.PreToolUse[] | select(.hooks[].command | endswith(\"/leak-guard.sh\")) | .matcher] | (index(\"WebSearch|WebFetch\")!=null) and (index(\"Bash\")==null)' '$S' >/dev/null"
# Bash egress is command-guard's surface now — leak-guard must not appear on Bash.
assert_ok "no leak-guard registration on the Bash matcher (consolidated into command-guard)" \
  bash -c "jq -e '[.hooks.PreToolUse[] | select(.matcher==\"Bash\") | .hooks[].command | select(endswith(\"/leak-guard.sh\"))] | length == 0' '$S' >/dev/null"

# Shared secret-patterns lib placed alongside the guards.
assert_file "shared hooks/lib placed" "$PROFILE/hooks/lib"

# command-guard is the SOLE Bash egress guard, registered with an absolute bun path
# (bun is mandatory when command-guard is selected; a missing bun ABORTS the install,
# tested in test_scn_install_missing_deps). This test runs with bun present.
if command -v bun >/dev/null 2>&1; then
  cmd="$(jq -r '.hooks.PreToolUse[].hooks[].command | select(endswith("/command-guard.ts"))' "$S")"
  [ -n "$cmd" ] && pass "command-guard registered (bun present)" || fail "command-guard registered (bun present)" "no command-guard.ts registration"
  assert_ok "command-guard registered under the Bash matcher" \
    bash -c "jq -e '[.hooks.PreToolUse[] | select(.matcher==\"Bash\") | .hooks[].command | select(endswith(\"/command-guard.ts\"))] | length == 1' '$S' >/dev/null"
  # The interpreter is invoked by ABSOLUTE path (shell-quoted, so a config dir with
  # spaces is safe): the command starts with `/` or `'/`.
  case "$cmd" in /*|\'/*) pass "command-guard uses an absolute interpreter path" ;; *) fail "command-guard uses an absolute interpreter path" "not absolute: $cmd" ;; esac
  case "$cmd" in *bun*command-guard.ts) pass "command-guard launched via bun" ;; *) fail "command-guard launched via bun" "no 'bun' in: $cmd" ;; esac
else
  pass "bun absent — command-guard registration shape skipped (per installer contract)"
fi

t_summary
