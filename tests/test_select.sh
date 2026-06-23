#!/usr/bin/env bash
# CT_ADDITIONS selection lever — the non-interactive subset selector (the menu
# reads /dev/tty, so this is how scripted installs and tests pick additions).
# Covers: exact-subset deploy, a NON-recommended addition + its config template,
# empty = none, and a typo failing loudly.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_select:"

inst() { # $1 = CT_ADDITIONS value, into a fresh sandbox; echoes the profile dir
  local sb; sb="$(sandbox)"; touch "$sb/.bashrc"
  CT_ADDITIONS="$1" SHELL=/bin/bash HOME="$sb" bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$sb/log" 2>&1
  printf '%s' "$sb/.claude-aka"
}

# Exact subset: only what was named, nothing else.
P="$(inst "wrap-up")"
assert_file "subset: wrap-up deployed"          "$P/commands/wrap-up.md"
[ -e "$P/hooks/leak-guard.ts" ] && fail "subset installs ONLY the named ids" "leak-guard leaked in" \
                               || pass "subset installs ONLY the named ids"

# A non-recommended addition installs when explicitly named, with its config template.
P="$(inst "harness-pointer")"
assert_file "non-recommended harness-pointer deployed" "$P/hooks/harness-pointer.sh"
assert_file "config template placed for config-driven hook" "$P/aka-claude-tools.config"

# Empty value installs nothing.
P="$(inst "")"
[ -z "$(ls -A "$P/hooks" 2>/dev/null)" ] && pass "empty CT_ADDITIONS installs no hooks" \
                                         || fail "empty CT_ADDITIONS installs no hooks" "hooks: $(ls "$P/hooks")"

# A typo'd id aborts loudly instead of silently dropping it.
sb="$(sandbox)"; touch "$sb/.bashrc"
CT_ADDITIONS="leak-guard no-such-addition" SHELL=/bin/bash HOME="$sb" bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$sb/out" 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "unknown id aborts (non-zero exit)" || fail "unknown id aborts (non-zero exit)" "exit was 0"
assert_lit "names the offending id" "no-such-addition" "$sb/out"

t_summary
