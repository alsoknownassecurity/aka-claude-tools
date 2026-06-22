#!/usr/bin/env bash
# test_egress_config_robustness.sh — two PR-review hardenings for the org-egress path,
# both exercised on the BUN-LESS floor (web-only install, no command-guard):
#   #47-a  A config that fails to SOURCE must not silently ship an empty "tier inactive"
#          sidecar — install warns loudly and still exits 0 (tier inactive until fixed).
#   #47-b  leak-guard gains the stale-config detection command-guard already has: when
#          aka-claude-tools.config drifts from the compiled sidecar, leak-guard WARNS
#          (advisory, never blocks). The sidecar's sourceHash is now computed with a
#          PORTABLE sha256 (not bun), so it is populated even on a bun-less install.
# Fully sandboxed: fake $HOME, throwaway profile; never touches a real ~/.claude*.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_egress_config_robustness:"

# Force the bun-less floor: drop bun's dir from PATH so install computes sourceHash via
# the shell sha256 and leak-guard re-hashes the same way — the exact web-only scenario.
NOBUN_PATH="$PATH"
if command -v bun >/dev/null 2>&1; then
  _bd="$(cd "$(dirname "$(command -v bun)")" && pwd)"
  NOBUN_PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "$_bd" | paste -sd: -)"
fi
PATH="$NOBUN_PATH" command -v bun >/dev/null 2>&1 \
  && echo "  note: bun still on PATH (symlinked elsewhere) — sourceHash is via sha256 regardless." \
  || echo "  (bun removed from PATH — genuine bun-less floor)"

# inst <config-body>  → installs leak-guard (web-only, no command-guard) with the given
# aka-claude-tools.config pre-placed, under the bun-less PATH. Sets SB / PROFILE / RC.
inst() {
  SB="$(sandbox)"; touch "$SB/.bashrc"
  PROFILE="$SB/.claude-aka"; mkdir -p "$PROFILE"
  printf '%s\n' "$1" > "$PROFILE/aka-claude-tools.config"
  PATH="$NOBUN_PATH" SHELL=/bin/bash HOME="$SB" CT_ADDITIONS="secure-settings leak-guard" \
    CT_NONINTERACTIVE=1 bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log" 2>&1
  RC=$?
}
# run a web query through the installed leak-guard; capture STDERR only.
lg_err() { printf '{"tool_name":"WebSearch","tool_input":{"query":"%s"}}' "$1" \
  | PATH="$NOBUN_PATH" bash "$PROFILE/hooks/leak-guard.sh" 2>&1 >/dev/null; }

# ── #47-a: a config that cannot be sourced → loud warning, NOT a silent disable ──────
inst 'CT_EGRESS_PATTERNS="unterminated'   # unclosed quote → source fails (syntax error)
assert_eq   "source-error config: install still exits 0" "0" "$RC"
assert_grep "source-error config: warns the org tier is inactive (not silent)" \
  'could not be sourced|org-marker tier is INACTIVE' "$SB/log"
assert_ok   "source-error config: sidecar pattern is empty (tier inactive)" \
  bash -c "jq -e '.pattern==\"\"' '$PROFILE/hooks/lib/org-egress.json' >/dev/null"

# ── #47-a edge: a config that sets the pattern but ENDS on a non-zero command sourced
#    fine — it must NOT trigger the "tier inactive" warning, and the pattern MUST compile.
inst $'CT_EGRESS_PATTERNS="acme\\.internal"\nfalse'
assert_eq   "pattern-set-but-nonzero-exit config: install exits 0" "0" "$RC"
assert_ngrep "pattern-set-but-nonzero-exit: NO misleading inactive warning" \
  'could not be sourced' "$SB/log"
assert_ok   "pattern-set-but-nonzero-exit: pattern still compiled" \
  bash -c "jq -e '.pattern|contains(\"acme\")' '$PROFILE/hooks/lib/org-egress.json' >/dev/null"

# ── #47-a (cross-vendor catch): a real SYNTAX error AFTER the pattern is set must still
#    be surfaced — never hidden just because a pattern happened to compile first. ──
inst $'CT_EGRESS_PATTERNS="acme\\.internal"\n"unterminated'
assert_eq   "syntax-error-after-pattern: install exits 0" "0" "$RC"
assert_grep "syntax-error-after-pattern: source failure is surfaced, not hidden" \
  'could not be sourced|sourced with an error' "$SB/log"

# ── #47-b: bun-less install still populates a real sha256 sourceHash ─────────────────
inst 'CT_EGRESS_PATTERNS="acme\.internal"'
assert_eq   "valid config: install exits 0" "0" "$RC"
SC="$PROFILE/hooks/lib/org-egress.json"
assert_ok   "bun-less install: sidecar carries a 64-char sha256 sourceHash" \
  bash -c "jq -e '(.sourceHash|type==\"string\") and (.sourceHash|length==64)' '$SC' >/dev/null"

# unchanged config → leak-guard emits NO stale warning
err="$(lg_err "hello world")"
case "$err" in
  *"changed since install"*|*STALE*) fail "unchanged config: no stale warning" "got: $err" ;;
  *) pass "unchanged config: no stale warning" ;;
esac

# drift the config → leak-guard WARNS it is stale
printf '\n# operator edited the config after install\n' >> "$PROFILE/aka-claude-tools.config"
err="$(lg_err "hello world")"
case "$err" in
  *"changed since install"*) pass "drifted config: leak-guard emits a stale-config warning" ;;
  *) fail "drifted config: leak-guard emits a stale-config warning" "got: $err" ;;
esac

# advisory only — a stale config must NEVER change the verdict (benign query still allowed)
printf '{"tool_name":"WebSearch","tool_input":{"query":"a benign query"}}' \
  | PATH="$NOBUN_PATH" bash "$PROFILE/hooks/leak-guard.sh" >/dev/null 2>&1; rc=$?
assert_eq "stale config is advisory: benign query still allowed (exit 0, not blocked)" "0" "$rc"

t_summary
