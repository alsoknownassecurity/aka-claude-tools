#!/usr/bin/env bash
# test_guards.sh — run the shared adversarial corpus against BOTH egress guards.
#
# Invariant (the behavioral single-source-of-truth for the two-layer design):
#   - every "block" case is blocked by AT LEAST ONE guard (exit 2)
#   - every "allow" case passes BOTH guards (neither exits 2)
# Plus FAIL-STATE checks: a missing patterns file must FAIL CLOSED on outbound
# commands (not silently allow) while still letting benign non-outbound through.
#
# No real profile is touched. Both guards are .ts and run under bun; if bun is absent
# the whole suite is skipped (with a note), since neither guard can run without it.
set -uo pipefail
cd "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"   # repo root
WEB=config/hooks/leak-guard.ts
TS=config/hooks/command-guard.ts
CORPUS=tests/corpus.json
PATTERNS=config/hooks/lib/secret-patterns.json
PASS=0; FAIL=0
echo "test_guards:"
# Both guards are .ts and run under bun (hard dependency). Without bun neither guard can
# run, so the suite is skipped rather than asserting against guards that can't execute.
if ! command -v bun >/dev/null 2>&1; then
  echo "  note: bun absent — both egress guards require bun; skipping (SUITE NOT EXERCISED)."
  exit 0
fi
command -v trufflehog >/dev/null 2>&1 && echo "note: trufflehog present — Tier 1 active (may add blocks)." || echo "note: trufflehog absent — regex tiers only."

field_for(){ [ "$1" = Bash ] && echo command || echo query; }
web_rc(){ printf '%s' "$1" | bun "$WEB" >/dev/null 2>&1; echo $?; }
ts_rc(){ printf '%s' "$1" | bun "$TS" >/dev/null 2>&1; echo $?; }

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

# ── FAIL-STATE: a CORRUPT patterns file (invalid regex fragment) must FAIL CLOSED on the
# web guard. leak-guard.ts builds the cred alternation via new RegExp(); a bad fragment
# throws → null → block. This is the documented "missing/corrupt → block" contract (the
# old bash version had a latent gap here — it allowed on a bad-but-nonempty pattern). ──
_cbak=$(mktemp); cp "$PATTERNS" "$_cbak"
printf '{"outboundInvocation":"x","credentialPatterns":[{"pattern":"sk_live_[0-9","label":"broken"}]}' > "$PATTERNS"
corrupt=$(web_rc '{"tool_name":"WebSearch","tool_input":{"query":"any web query"}}')
cp "$_cbak" "$PATTERNS"; rm -f "$_cbak"
[ "$corrupt" = 2 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); printf '  \033[31m✗ FAIL-OPEN HOLE: corrupt patterns did not block web query (web=%s)\033[0m\n' "$corrupt"; }

# ── command-guard-only: startup-file writes (persistence vector) ─────────────────
# Folded in from the retired startup-write-guard addition. These are NOT in the shared
# corpus because they're a command-guard-only (Bash) concern; bun is guaranteed present
# here (the suite exits early above if bun is absent).
for w in 'echo x >> ~/.zshrc' 'cat f > ~/.bashrc' "sed -i 's/a/b/' ~/.zshenv" 'tee -a ~/.profile <<<z' 'cp e ~/.bash_profile'; do
  j=$(jq -n --arg v "$w" '{tool_name:"Bash",tool_input:{command:$v}}')
  [ "$(ts_rc "$j")" = 2 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); printf '  \033[31m✗ command-guard did NOT block startup-write: %s\033[0m\n' "$w"; }
done
# Reads, unrelated writes, and the sanctioned alias writer must NOT be blocked.
for a in 'cat ~/.zshrc' 'grep alias ~/.zshrc' 'echo hi >> notes.txt' './install.sh --alias'; do
  j=$(jq -n --arg v "$a" '{tool_name:"Bash",tool_input:{command:$v}}')
  [ "$(ts_rc "$j")" = 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); printf '  \033[31m✗ command-guard OVER-blocked: %s\033[0m\n' "$a"; }
done

printf '  \033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
