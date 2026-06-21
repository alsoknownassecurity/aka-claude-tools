#!/usr/bin/env bash
# Scenario lib_orphan (cross-vendor finding): the shared egress-guard lib
# hooks/lib/secret-patterns.json is placed whenever leak-guard OR command-guard is
# selected, but it is owned by NEITHER addition's addition_owned_paths list. So
# deselecting the guard(s) left it orphaned — the per-addition deselect loop never
# removes a shared payload. The matrix missed it because manifest_deep deselects
# one addition at a time. Fix: remove the shared lib when NEITHER guard remains.
# Fully sandboxed: fake $HOME, --defaults --no-auth-inherit.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_lib_orphan:"

SB="$(sandbox)"; touch "$SB/.bashrc"
P="$SB/.claude-aka"
LIB="$P/hooks/lib/secret-patterns.json"

# Install a guard → the shared lib is placed.
CT_ADDITIONS="leak-guard" SHELL=/bin/bash HOME="$SB" \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log1" 2>&1
assert_eq   "install leak-guard exits 0" "0" "$?"
assert_file "shared egress-guard lib placed" "$LIB"

# Re-run with NO guard selected → the shared lib must be removed, not orphaned.
CT_ADDITIONS="secure-settings" SHELL=/bin/bash HOME="$SB" \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log2" 2>&1
assert_eq "deselect re-run (no guard) exits 0" "0" "$?"
if [ -e "$LIB" ]; then
  fail "shared lib removed when no guard remains" "RESIDUE: $LIB survived deselect of all guards"
else
  pass "shared lib removed when no guard remains"
fi

t_summary
