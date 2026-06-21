#!/usr/bin/env bash
# Scenario edge_security — a crafted-but-VALID settings.json defeats the secure
# baseline install.
#
# The installer validates that an existing settings.json PARSES as JSON (install.sh
# ~L794) and frames a corrupt/truncated file with a named, recoverable die().
# But it does NOT validate the SHAPE of the fields the merge/prune logic depends on.
# A settings.json that is perfectly valid JSON yet carries a wrong-TYPED
# permissions array — e.g. `"permissions":{"deny":"Read(/etc/**)"}` (a string, not
# an array), which Claude Code itself would simply ignore — slips past the guard
# and then crashes deep inside the merge/prune jq:
#
#     jq: error: string (...) and array (...) cannot be subtracted   (prune_perms_env)
#     jq: error: string (...) and array (...) cannot be added        (merge_settings)
#
# Consequence (adversarial / security-boundary):
#   • the installer ABORTS with rc!=0 and a RAW `jq: error` — the exact unframed
#     failure the corrupt-JSON guard was added to prevent — with no actionable
#     "fix or re-run with --clean" message.
#   • the kit's SECURE BASELINE (secure-settings deny rules) is NEVER written, so
#     the profile is left WITHOUT the credential-read / shell-rc-write denies the
#     user asked for. The secure baseline does not end up enforced.
#   • (bonus) it even prints a misleading "✓ permissions.deny: adopted N new
#     rule(s)" line immediately before crashing — those rules are never persisted.
#
# Fully sandboxed: fake $HOME, --defaults --no-auth-inherit, never touches a real
# ~/.claude*. This test PINS the bug: it asserts the install SUCCEEDS and the kit
# baseline lands. It is RED against current install.sh (correct — it documents an
# open defect). A fix (validate field shapes / coerce / frame the error) turns it
# green.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_edge_security:"

# Representative kit deny that secure-settings ships — must end up enforced.
KIT_DENY="$(jq -r '.permissions.deny | map(select(. == "Read(**/.env)")) | .[0] // .[0]' "$REPO_ROOT/config/settings.base.json")"
[ -z "$KIT_DENY" ] && KIT_DENY="$(jq -r '.permissions.deny[0]' "$REPO_ROOT/config/settings.base.json")"

run_case() {
  local label="$1" seed="$2"
  local SB P S rc
  SB="$(sandbox)"; touch "$SB/.bashrc"
  P="$SB/.claude-aka"; mkdir -p "$P"
  printf '%s' "$seed" > "$P/settings.json"
  # sanity: the seed itself is valid JSON (the whole point — it passes the guard).
  assert_ok "[$label] seed is valid JSON (slips past the parse guard)" jq -e . "$P/settings.json"

  CT_ADDITIONS="secure-settings leak-guard" SHELL=/bin/bash HOME="$SB" \
    bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log" 2>&1
  rc=$?
  S="$P/settings.json"

  # The install must not abort.
  assert_eq "[$label] install exits 0 (no abort on a valid-but-odd settings.json)" "0" "$rc"
  # It must never spew a raw jq parse/type error at the user.
  assert_nlit "[$label] no raw 'jq: error' leaked to the user" "jq: error" "$SB/log"
  # The result must be valid JSON.
  assert_ok "[$label] settings.json is valid JSON after install" jq -e . "$S"
  # The secure baseline must actually be enforced (kit deny present).
  assert_ok "[$label] kit secure-baseline deny enforced" \
    bash -c "jq -e --arg r '$KIT_DENY' '(.permissions.deny // []) | (type==\"array\") and (index(\$r) != null)' '$S' >/dev/null"
  # No orphan settings.json.tmp left behind by a failed merge redirection.
  assert_ok "[$label] no orphan settings.json.tmp" bash -c "[ ! -e '$P/settings.json.tmp' ]"
}

# A power user (or an attacker who can write the profile) leaves a wrong-typed
# permissions array. Claude Code ignores a non-array deny; the installer should
# not be defeated by it — it should still lay down the secure baseline.
run_case "deny-as-string"  '{"permissions":{"deny":"Read(/etc/**)"},"theme":"dark"}'
run_case "allow-as-string" '{"permissions":{"allow":"Bash(x)"}}'
run_case "deny-as-number"  '{"permissions":{"deny":5}}'

t_summary
