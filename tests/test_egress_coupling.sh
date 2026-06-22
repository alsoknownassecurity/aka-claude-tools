#!/usr/bin/env bash
# test_egress_coupling.sh — the leak-guard/command-guard coupling control. After the
# consolidation leak-guard is WEB-only and command-guard owns Bash egress. The id
# 'leak-guard' changed coverage surface, so the installer must LOUDLY catch the UPGRADE
# TRANSITION that would silently drop Bash coverage (an existing profile whose leak-guard
# was on the Bash matcher, re-installed without command-guard) — while still allowing a
# FRESH, intentional web-only install (warn, not die).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_egress_coupling:"

# ── fresh web-only install (no prior leak-guard-on-Bash) → WARN, succeeds ──
SB="$(sandbox)"; touch "$SB/.bashrc"
SHELL=/bin/bash HOME="$SB" CT_ADDITIONS="secure-settings leak-guard" CT_NONINTERACTIVE=1 \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log" 2>&1
rc=$?
assert_ok   "fresh web-only install succeeds (warn, not die)" bash -c "[ $rc -eq 0 ]"
assert_grep "fresh web-only install WARNS about unguarded Bash" 'UNGUARDED' "$SB/log"
PROFILE="$SB/.claude-aka"; S="$PROFILE/settings.json"

# ── upgrade TRANSITION: forge the pre-consolidation leak-guard-on-Bash registration,
#    re-install without command-guard → must ABORT (silent-coverage-drop guard) ──
jq --arg c "$PROFILE/hooks/leak-guard.sh" \
  '.hooks.PreToolUse += [{matcher:"Bash",hooks:[{type:"command",command:$c}]}]' "$S" > "$S.t" && mv "$S.t" "$S"
SHELL=/bin/bash HOME="$SB" CT_ADDITIONS="secure-settings leak-guard" CT_NONINTERACTIVE=1 \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log2" 2>&1
rc2=$?
assert_ok   "upgrade transition (prior leak-guard-on-Bash, no command-guard) ABORTS" bash -c "[ $rc2 -ne 0 ]"
assert_grep "abort names the silent Bash-coverage drop" 'SILENTLY drop Bash|Bash egress' "$SB/log2"

# ── same transition + explicit ack → succeeds ──
SHELL=/bin/bash HOME="$SB" CT_ALLOW_UNGUARDED_BASH=1 CT_ADDITIONS="secure-settings leak-guard" CT_NONINTERACTIVE=1 \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log3" 2>&1
rc3=$?
assert_ok   "transition + CT_ALLOW_UNGUARDED_BASH=1 proceeds" bash -c "[ $rc3 -eq 0 ]"

# ── selecting BOTH guards: no warn, no die (command-guard covers Bash) ──
if command -v bun >/dev/null 2>&1; then
  SB2="$(sandbox)"; touch "$SB2/.bashrc"
  SHELL=/bin/bash HOME="$SB2" CT_ADDITIONS="secure-settings leak-guard command-guard" CT_NONINTERACTIVE=1 \
    bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB2/log" 2>&1
  rc4=$?
  assert_ok    "both guards selected: install succeeds" bash -c "[ $rc4 -eq 0 ]"
  assert_ngrep "both guards selected: no unguarded-Bash warning" 'UNGUARDED' "$SB2/log"
else
  echo "  note: bun absent — both-guards case skipped (command-guard needs bun)."
fi

t_summary
