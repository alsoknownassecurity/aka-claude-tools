#!/usr/bin/env bash
# Guard registration shape — the egress guards must be wired into settings.json the
# way the design requires, or they silently don't fire:
#   - leak-guard registered TWICE: matcher "WebSearch|WebFetch" AND matcher "Bash"
#     (the Bash arm is fast-gated; without it, outbound Bash egress is unguarded).
#   - command-guard registered with an ABSOLUTE bun path (hook subshells lack bun on
#     PATH, so a bare shebang can silently fail to launch).
#   - the shared lib/ (secret-patterns corpus) placed whenever a guard is selected.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_guard_registration:"

SB="$(sandbox)"; touch "$SB/.bashrc"
PROFILE="$SB/.claude-aka"
SHELL=/bin/bash HOME="$SB" bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log" 2>&1
S="$PROFILE/settings.json"

# leak-guard appears under exactly two registrations, one per required matcher.
assert_ok "leak-guard registered exactly twice" \
  bash -c "jq -e '[.hooks.PreToolUse[] | select(.hooks[].command | endswith(\"/leak-guard.sh\"))] | length == 2' '$S' >/dev/null"
assert_ok "leak-guard registered under WebSearch|WebFetch and Bash" \
  bash -c "jq -e '[.hooks.PreToolUse[] | select(.hooks[].command | endswith(\"/leak-guard.sh\")) | .matcher] | (index(\"Bash\")!=null) and (index(\"WebSearch|WebFetch\")!=null)' '$S' >/dev/null"

# Shared secret-patterns lib placed alongside the guards.
assert_file "shared hooks/lib placed" "$PROFILE/hooks/lib"

# command-guard is bun-gated: only assert its registration shape when bun is present
# (matches the installer contract — absent bun ⇒ not registered, tested elsewhere).
if command -v bun >/dev/null 2>&1; then
  cmd="$(jq -r '.hooks.PreToolUse[].hooks[].command | select(endswith("/command-guard.ts"))' "$S")"
  [ -n "$cmd" ] && pass "command-guard registered (bun present)" || fail "command-guard registered (bun present)" "no command-guard.ts registration"
  # The interpreter is invoked by ABSOLUTE path (shell-quoted, so a config dir
  # with spaces is safe): the command starts with `/` or `'/`.
  case "$cmd" in /*|\'/*) pass "command-guard uses an absolute interpreter path" ;; *) fail "command-guard uses an absolute interpreter path" "not absolute: $cmd" ;; esac
  case "$cmd" in *bun*command-guard.ts) pass "command-guard launched via bun" ;; *) fail "command-guard launched via bun" "no 'bun' in: $cmd" ;; esac
else
  pass "bun absent — command-guard registration shape skipped (per installer contract)"
fi

t_summary
