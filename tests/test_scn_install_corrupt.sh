#!/usr/bin/env bash
# Scenario T10 (scn_install_corrupt): INSTALL/messy — corrupt / partial PRIOR state.
#
# Two real-world damaged-profile situations a re-run must handle correctly:
#
#   PART A — MALFORMED settings.json (truncated JSON).
#     A prior write was interrupted, leaving settings.json as invalid JSON. The
#     installer reads the EXISTING settings.json verbatim into the merge. It must
#     FAIL LOUDLY and ACTIONABLY — not silently corrupt/overwrite the file, and
#     not bury the failure in a cryptic raw `jq: parse error`. The user should be
#     able to tell, from the output, WHICH file is broken and what to do.
#     Hard requirements (assertions):
#       • the installer exits NON-ZERO (no silent success),
#       • the malformed settings.json is NOT silently rewritten to something else
#         (no half-merged corruption clobbering the user's file),
#       • the output names settings.json AND signals invalid/corrupt JSON in an
#         installer-level message (actionable), not just a bare jq stack trace.
#
#   PART B — HALF-WRITTEN prior install with VALID JSON: a kit hook FILE is
#     missing but its registration still sits in a (valid) settings.json. A
#     re-run must REDEPLOY the missing hook file idempotently:
#       • the hook file comes back, byte-identical to the kit version,
#       • settings.json stays valid JSON,
#       • the hook's registration is not duplicated (idempotent — exactly the
#         kit's canonical matcher count, no stray extra reg).
#
# Layer-in-place path (existing NON-default profile, --defaults → decline rebuild)
# so we exercise the in-place settings merge against the damaged on-disk file —
# the exact code that reads `existing="$(cat settings.json)"`.
#
# Fully sandboxed: fake $HOME, fake bash rc, --no-auth-inherit, non-default
# $HOME/.claude-aka target. Never touches a real ~/.claude*.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_install_corrupt:"

# Deterministic recommended subset needing no optional runtime (bun/rtk/trufflehog):
# leak-guard ships a marked kit hook file + a canonical registration; secure-settings
# ships kit denies. Both land via --defaults without external tools.
SEL="secure-settings leak-guard"

# ── PART A: malformed settings.json must fail loudly + actionably ──────────────
SB_A="$(sandbox)"; touch "$SB_A/.bashrc"; PA="$SB_A/.claude-aka"
run_a() { CT_ADDITIONS="$SEL" SHELL=/bin/bash HOME="$SB_A" \
          bash "$REPO_ROOT/install.sh" "$@" --defaults --no-auth-inherit >"$SB_A/log" 2>&1; }

run_a; assert_eq "PART A: baseline install exits 0" "0" "$?"
SA="$PA/settings.json"
assert_ok "PART A: baseline settings.json is valid JSON" jq -e . "$SA"

# Corrupt it: a TRUNCATED JSON object (interrupted write). Keep an exact copy so
# we can prove the installer doesn't silently rewrite the user's broken file.
MALFORMED='{"permissions": {"deny": ["Read(/secret/**)"'
printf '%s' "$MALFORMED" > "$SA"
assert_fail "PART A: malformed settings.json is NOT valid JSON (setup sanity)" \
  jq -e . "$SA"

# Re-run the installer over the corrupt profile (layer-in-place).
run_a; rc_a=$?

# (1) MUST NOT silently succeed — a corrupt config can't be safely merged.
assert_ok "PART A: installer exits NON-ZERO on malformed settings.json" \
  bash -c "[ '$rc_a' -ne 0 ]"

# (2) MUST NOT silently corrupt/overwrite the user's file. Either it's left
#     byte-for-byte as the user's broken input (so they can repair it), or the
#     installer rewrote it to *valid* JSON. What must NEVER happen: a third,
#     still-invalid, half-merged state that's neither the original nor recoverable.
if [ "$(cat "$SA")" = "$MALFORMED" ]; then
  pass "PART A: malformed settings.json left untouched (user can repair it)"
elif jq -e . "$SA" >/dev/null 2>&1; then
  pass "PART A: settings.json was rewritten to VALID JSON (recovered)"
else
  fail "PART A: settings.json silently mangled to a new INVALID state" \
    "neither the original input nor valid JSON: $(cat "$SA")"
fi

# (3) ACTIONABLE message: the failure must name settings.json AND signal the JSON
#     is invalid/corrupt at the installer level — not just a bare `jq: parse
#     error` the user can't act on. Expected behavior; pins the gap if absent.
assert_grep "PART A: output names settings.json in the failure" \
  'settings\.json' "$SB_A/log"
assert_grep "PART A: output signals invalid/corrupt JSON (actionable)" \
  '([Ii]nvalid|[Mm]alformed|[Cc]orrupt|not valid JSON|could not parse|failed to parse)' \
  "$SB_A/log"
# A raw, unframed `jq: parse error` with no installer-level framing is NOT
# actionable — the user sees an internal stack trace, not guidance.
assert_ngrep "PART A: failure is not ONLY a raw jq parse error" \
  '^jq: error|jq: parse error' "$SB_A/log"

# ── PART B: missing hook + VALID JSON must redeploy idempotently ───────────────
SB_B="$(sandbox)"; touch "$SB_B/.bashrc"; PB="$SB_B/.claude-aka"
run_b() { CT_ADDITIONS="$SEL" SHELL=/bin/bash HOME="$SB_B" \
          bash "$REPO_ROOT/install.sh" "$@" --defaults --no-auth-inherit >"$SB_B/log" 2>&1; }

run_b; assert_eq "PART B: baseline install exits 0" "0" "$?"
SB="$PB/settings.json"
HOOK="$PB/hooks/leak-guard.sh"
assert_file "PART B: kit hook present after baseline" "$HOOK"

# Half-written prior install: the hook FILE is gone but its registration remains
# in a still-VALID settings.json (a partial deploy / a user who rm'd the file).
rm -f "$HOOK"
assert_fail "PART B: kit hook file removed (setup)" bash -c "[ -e '$HOOK' ]"
assert_ok "PART B: settings still valid JSON before re-run" jq -e . "$SB"
assert_ok "PART B: leak-guard registration still present (orphaned reg)" \
  bash -c "jq -e '[.hooks.PreToolUse[]?.hooks[].command] | any(endswith(\"/leak-guard.sh\"))' '$SB' >/dev/null"

# Re-run: this is the upgrade/repair path — the missing hook must come back.
run_b; rc_b=$?
assert_eq "PART B: re-run over half-written profile exits 0" "0" "$rc_b"
assert_file "PART B: missing kit hook REDEPLOYED" "$HOOK"
if diff -q "$REPO_ROOT/config/hooks/leak-guard.sh" "$HOOK" >/dev/null 2>&1; then
  pass "PART B: redeployed hook is byte-identical to the kit version"
else
  fail "PART B: redeployed hook is byte-identical to the kit version" \
    "profile copy differs from config/hooks/leak-guard.sh"
fi
assert_ok "PART B: settings.json still valid JSON after re-run" jq -e . "$SB"

# Idempotent registration: leak-guard registered under EXACTLY the kit's canonical
# matcher (WebSearch|WebFetch = 1; web-only, Bash is command-guard's), no duplicate
# stray reg from the orphaned one we left behind.
n_wg=$(jq '[.hooks.PreToolUse[] | select(.hooks[].command | endswith("/leak-guard.sh"))] | length' "$SB")
assert_eq "PART B: leak-guard registered under exactly the kit's 1 matcher (idempotent)" "1" "$n_wg"
n_tot=$(jq '.hooks.PreToolUse | length' "$SB")
n_uniq=$(jq '.hooks.PreToolUse | unique_by(tojson) | length' "$SB")
assert_eq "PART B: no duplicate PreToolUse registrations after redeploy" "$n_tot" "$n_uniq"

t_summary
