#!/usr/bin/env bash
# test_sidecar_compile.sh — install-time compilation + STRICT validation of the
# org-egress sidecar from CT_EGRESS_PATTERNS. This is the P2-correction boundary:
# the shell config is compiled into INERT JSON (no hook ever sources shell), and a
# non-portable regex is REJECTED at install so the two engines (grep -E web / JS Bash)
# can't diverge silently.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_sidecar_compile:"

if ! command -v bun >/dev/null 2>&1; then
  echo "  note: bun absent — sidecar hashing/validation uses bun; test skipped."
  exit 0
fi

inst(){  # $1 = config body → sets RC + SB + PROFILE
  SB="$(sandbox)"; touch "$SB/.bashrc"
  PROFILE="$SB/.claude-aka"; mkdir -p "$PROFILE"
  printf '%s\n' "$1" > "$PROFILE/aka-claude-tools.config"
  SHELL=/bin/bash HOME="$SB" CT_ADDITIONS="leak-guard command-guard" CT_NONINTERACTIVE=1 \
    bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log" 2>&1
  RC=$?
}

# ── valid portable pattern → install succeeds, sidecar carries pattern + hash ──
inst 'CT_EGRESS_PATTERNS="acme\.internal|10\.[0-9]+\.[0-9]+\.[0-9]+"'
assert_ok   "valid pattern: install succeeds" bash -c "[ $RC -eq 0 ]"
SC="$PROFILE/hooks/lib/org-egress.json"
assert_file "valid pattern: sidecar written" "$SC"
assert_ok   "valid pattern: sidecar is pure JSON (no shell-sourcing surface)" jq -e . "$SC"
assert_ok   "valid pattern: sidecar carries the compiled pattern" \
  bash -c "jq -e '(.pattern|contains(\"acme\")) and (.pattern|contains(\"[0-9]\"))' '$SC' >/dev/null"
assert_ok   "valid pattern: sidecar carries a sha256 sourceHash" \
  bash -c "jq -e '(.sourceHash|type==\"string\") and (.sourceHash|length==64)' '$SC' >/dev/null"

# ── non-portable constructs are REJECTED at install (would diverge grep -E vs JS) ──
for bad in '10\.\d+' '[[:alpha:]]+\.internal' '(?=secret)'; do
  inst "CT_EGRESS_PATTERNS=\"$bad\""
  assert_ok   "non-portable pattern aborts the install: $bad" bash -c "[ $RC -ne 0 ]"
  assert_grep "rejection names the non-portable construct: $bad" 'non-portable regex|portable subset' "$SB/log"
done

# ── empty pattern → install succeeds, sidecar present but org tier inactive ──
inst 'CT_EGRESS_PATTERNS=""'
assert_ok "empty pattern: install succeeds" bash -c "[ $RC -eq 0 ]"
assert_ok "empty pattern: sidecar pattern empty (org tier inactive)" \
  bash -c "jq -e '.pattern==\"\"' '$PROFILE/hooks/lib/org-egress.json' >/dev/null"

t_summary
