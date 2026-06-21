#!/usr/bin/env bash
# Idempotency — re-running the installer for the SAME profile must converge, not
# accumulate. A duplicate hook registration on re-run was a real bug (#12); this
# pins the invariant. Fully sandboxed: fake $HOME, bash rc, --no-auth-inherit.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_idempotency:"

SB="$(sandbox)"
RC="$SB/.bashrc"; touch "$RC"          # deterministic rc target for the alias block
PROFILE="$SB/.claude-aka"
run() { SHELL=/bin/bash HOME="$SB" bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log" 2>&1; }

run; rc1=$?
cp "$PROFILE/settings.json" "$SB/after1.json"
run; rc2=$?
cp "$PROFILE/settings.json" "$SB/after2.json"

assert_eq "first  install exits 0" "0" "$rc1"
assert_eq "second install exits 0" "0" "$rc2"

# Settings converge: canonical (jq -S, key-order/whitespace-insensitive) equality
# across the two runs — catches ANY growth/dup regardless of structure.
if diff <(jq -S . "$SB/after1.json") <(jq -S . "$SB/after2.json") >/dev/null 2>&1; then
  pass "settings.json is canonical-identical across re-runs"
else
  fail "settings.json is canonical-identical across re-runs" "re-run changed settings (non-idempotent)"
fi

# Exactly ONE managed alias block (each block has an opening >>> marker).
n_block=$(grep -c '>>> aka-claude-tools managed' "$RC")
assert_eq "single managed alias block in rc" "1" "$n_block"

# No duplicate hook registrations: every PreToolUse entry (matcher+command) unique.
# (leak-guard is registered under two DIFFERENT matchers by design — distinct entries.)
n_tot=$(jq '.hooks.PreToolUse | length' "$SB/after2.json")
n_uniq=$(jq '.hooks.PreToolUse | unique_by(tojson) | length' "$SB/after2.json")
assert_eq "no duplicate PreToolUse registrations" "$n_tot" "$n_uniq"

t_summary
