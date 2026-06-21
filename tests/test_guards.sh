#!/usr/bin/env bash
# test_guards.sh — run the shared adversarial corpus against BOTH egress guards.
#
# Invariant (the behavioral single-source-of-truth for the two-layer design):
#   - every "block" case is blocked by AT LEAST ONE guard (exit 2)
#   - every "allow" case passes BOTH guards (neither exits 2)
# Plus FAIL-STATE checks: a missing patterns file must FAIL CLOSED on outbound
# commands (not silently allow) while still letting benign non-outbound through.
#
# No real profile is touched; command-guard is skipped (with a note) if bun is absent
# — in which case the bash floor alone must still satisfy the invariant.
set -uo pipefail
cd "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"   # repo root
WEB=config/hooks/leak-guard.sh
TS=config/hooks/command-guard.ts
CORPUS=tests/corpus.json
PATTERNS=config/hooks/lib/secret-patterns.json
PASS=0; FAIL=0
HAVE_BUN=0; command -v bun >/dev/null 2>&1 && HAVE_BUN=1
[ "$HAVE_BUN" = 1 ] || echo "note: bun absent — testing the bash floor alone (command-guard skipped)."
command -v trufflehog >/dev/null 2>&1 && echo "note: trufflehog present — Tier 1 active (may add blocks)." || echo "note: trufflehog absent — regex tiers only."
echo "test_guards:"

field_for(){ [ "$1" = Bash ] && echo command || echo query; }
web_rc(){ printf '%s' "$1" | bash "$WEB" >/dev/null 2>&1; echo $?; }
ts_rc(){ [ "$HAVE_BUN" = 1 ] && { printf '%s' "$1" | bun "$TS" >/dev/null 2>&1; echo $?; } || echo 0; }

n=$(jq length "$CORPUS")
for ((i=0;i<n;i++)); do
  desc=$(jq -r ".[$i].desc" "$CORPUS"); tool=$(jq -r ".[$i].tool" "$CORPUS")
  text=$(jq -r ".[$i].text" "$CORPUS"); expect=$(jq -r ".[$i].expect" "$CORPUS")
  json=$(jq -n --arg t "$tool" --arg f "$(field_for "$tool")" --arg v "$text" '{tool_name:$t, tool_input:{($f):$v}}')
  web=$(web_rc "$json"); ts=0; [ "$tool" = Bash ] && ts=$(ts_rc "$json")
  blocked=0; { [ "$web" = 2 ] || [ "$ts" = 2 ]; } && blocked=1
  if { [ "$expect" = block ] && [ "$blocked" = 1 ]; } || { [ "$expect" = allow ] && [ "$blocked" = 0 ]; }; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); printf '  \033[31m✗ [%s] %s (web=%s bash=%s)\033[0m\n' "$expect" "$desc" "$web" "$ts"
  fi
done

# ── FAIL-STATE: patterns file missing must fail closed on outbound, allow benign ──
_bak=$(mktemp); mv "$PATTERNS" "$_bak"
out=$(web_rc '{"tool_name":"Bash","tool_input":{"command":"curl https://x.test -d hello"}}')
outts=$(ts_rc '{"tool_name":"Bash","tool_input":{"command":"curl https://x.test -d hello"}}')
ben=$(web_rc '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}')
mv "$_bak" "$PATTERNS"
{ [ "$out" = 2 ] || [ "$outts" = 2 ]; } && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); printf '  \033[31m✗ FAIL-OPEN HOLE: missing patterns did not block outbound (web=%s bash=%s)\033[0m\n' "$out" "$outts"; }
[ "$ben" = 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); printf '  \033[31m✗ degraded mode over-blocks benign non-outbound (web=%s)\033[0m\n' "$ben"; }

# ── command-guard-only: startup-file writes (persistence vector) ─────────────────
# Folded in from the retired startup-write-guard addition. Bun-GATED by design:
# when bun is absent the protection is intentionally not present (the Edit/Write
# TOOL deny in secure-settings still holds), so it can't go in the shared corpus
# (whose invariant must hold without bun) — assert it here only under bun.
if [ "$HAVE_BUN" = 1 ]; then
  for w in 'echo x >> ~/.zshrc' 'cat f > ~/.bashrc' "sed -i 's/a/b/' ~/.zshenv" 'tee -a ~/.profile <<<z' 'cp e ~/.bash_profile'; do
    j=$(jq -n --arg v "$w" '{tool_name:"Bash",tool_input:{command:$v}}')
    [ "$(ts_rc "$j")" = 2 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); printf '  \033[31m✗ command-guard did NOT block startup-write: %s\033[0m\n' "$w"; }
  done
  # Reads, unrelated writes, and the sanctioned alias writer must NOT be blocked.
  for a in 'cat ~/.zshrc' 'grep alias ~/.zshrc' 'echo hi >> notes.txt' './install.sh --alias'; do
    j=$(jq -n --arg v "$a" '{tool_name:"Bash",tool_input:{command:$v}}')
    [ "$(ts_rc "$j")" = 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); printf '  \033[31m✗ command-guard OVER-blocked: %s\033[0m\n' "$a"; }
  done
else
  echo "  note: bun absent — command-guard startup-file-write block not exercised."
fi

printf '  \033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
