#!/usr/bin/env bash
# Scenario T11 (scn_install_missing_deps): INSTALL/dep-missing — graceful behavior
# when a dependency is absent from PATH. Two distinct contracts:
#
#   • jq ABSENT  → jq is the REQUIRED engine (it drives the whole settings merge).
#                  The preflight `ensure_dep jq "jq (required)" 1` must BLOCK the
#                  install (non-zero exit) and print an actionable install hint —
#                  it must NOT proceed and must NOT create the profile dir.
#
#   • bun ABSENT (jq present) → bun is the runtime for ONLY the command-guard egress
#                  hook. Its absence must DEGRADE GRACEFULLY: command-guard is NOT
#                  registered (and its .ts artifact NOT placed), a LOUD warning is
#                  emitted, but the install still SUCCEEDS and every other selected
#                  addition still lands. A security guard silently skipped would be
#                  worse than a noisy one, so the skip must be explicit + the rest
#                  must be unaffected.
#
# Method: PATH-stubbed sandbox. We build a curated bin dir containing symlinks to
# every external tool the installer needs, then OMIT exactly one (jq, or bun) to
# simulate that tool being absent from the user's machine — without touching the
# host's real toolchain. Running with PATH=<stub> makes `command -v <tool>` fail
# for the omitted tool only.
#
# Fully sandboxed: fake $HOME, fake bash rc, --defaults --no-auth-inherit, default
# $HOME/.claude-aka target. Never touches a real ~/.claude*.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_install_missing_deps:"

# ── build a curated stub PATH (symlinks to real tools), omitting one dep ───────
# Pass the name(s) to OMIT as args. Everything the installer + common.sh touch is
# symlinked from its real resolved location so the script runs normally except for
# the omitted tool, whose `command -v` lookup will fail.
NEED_TOOLS="bash sh env jq git awk sed grep egrep fgrep find mktemp dirname \
basename cat cp mv rm mkdir rmdir chmod date tr wc sort head tail cut printf \
echo ln touch uname sleep comm diff stat tee xargs expr id whoami getopt \
bun node curl"

make_stub_path() {
  # $1 = stub dir, remaining args = tool names to OMIT
  local stub="$1"; shift
  local omit=" $* "
  mkdir -p "$stub"
  local t real
  for t in $NEED_TOOLS; do
    case "$omit" in *" $t "*) continue ;; esac      # skip omitted tools
    real="$(command -v "$t" 2>/dev/null || true)"
    [ -n "$real" ] && ln -sf "$real" "$stub/$t"
  done
}

# ════════════════════════════════════════════════════════════════════════════
# CASE 1 — jq ABSENT → required dep blocks the install
# ════════════════════════════════════════════════════════════════════════════
SB1="$(sandbox)"
RC1="$SB1/.bashrc"; touch "$RC1"
PROFILE1="$SB1/.claude-aka"
STUB1="$SB1/stubbin"
make_stub_path "$STUB1" jq
out1="$SB1/install.log"

# Sanity: the stub PATH itself must be usable (bash/git/sed present) and jq must
# genuinely be unreachable through it — otherwise the case proves nothing.
assert_ok   "stub PATH has a working bash" \
  env -i PATH="$STUB1" bash -c 'true'
assert_fail "jq is unreachable on the jq-omitted stub PATH" \
  env -i PATH="$STUB1" bash -c 'command -v jq'

# Run the installer with ONLY the jq-less stub on PATH. HOME/SHELL still flow in.
env -i PATH="$STUB1" HOME="$SB1" SHELL=/bin/bash \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$out1" 2>&1
rc1=$?

assert_ok   "jq absent: install exits NON-zero (blocked)" \
  bash -c "[ '$rc1' -ne 0 ]"
# The block must come from the required-dep preflight, with an actionable hint.
assert_grep "jq absent: reports jq is required" \
  'jq.*required|required.*jq' "$out1"
assert_grep "jq absent: gives an install instruction" \
  'Install it first|install manually|install via|brew|apt|re-run' "$out1"
# It must FAIL CLOSED: no profile dir, no settings, no alias written.
[ -e "$PROFILE1" ] && fail "jq absent: profile dir NOT created" "it exists at $PROFILE1" \
                    || pass "jq absent: profile dir NOT created"
assert_nlit "jq absent: no alias block written to rc" \
  ">>> aka-claude-tools managed: aka" "$RC1"

# ════════════════════════════════════════════════════════════════════════════
# CASE 2 — bun ABSENT (jq present). bun is a HARD dependency of command-guard (a
# default-on SECURITY hook), so the contract is SELECTION-dependent:
#   2a) command-guard SELECTED   → bun required → install ABORTS, fail-closed.
#   2b) command-guard DESELECTED → bun not needed → install SUCCEEDS.
# (No soft-skip: shipping a default-on security guard silently disabled is worse
# than a failed install. leak-guard still carries pipe-to-shell in this PR, so a
# leak-guard-only selection is fully protected WITHOUT bun.)
# ════════════════════════════════════════════════════════════════════════════

# ── 2a: command-guard selected + bun absent → abort, fail-closed ─────────────
SB2="$(sandbox)"
RC2="$SB2/.bashrc"; touch "$RC2"
PROFILE2="$SB2/.claude-aka"
STUB2="$SB2/stubbin"
make_stub_path "$STUB2" bun
out2="$SB2/install.log"

# Sanity: jq present, bun absent on this stub PATH.
assert_ok   "jq IS reachable on the bun-omitted stub PATH" \
  env -i PATH="$STUB2" bash -c 'command -v jq'
assert_fail "bun is unreachable on the bun-omitted stub PATH" \
  env -i PATH="$STUB2" bash -c 'command -v bun'

SEL2A="secure-settings leak-guard command-guard wrap-up"
env -i PATH="$STUB2" HOME="$SB2" SHELL=/bin/bash CT_ADDITIONS="$SEL2A" \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$out2" 2>&1
rc2a=$?

assert_ok   "bun absent + command-guard selected: install exits NON-zero (aborted)" \
  bash -c "[ '$rc2a' -ne 0 ]"
assert_grep "bun absent (selected): reports bun is required (not a silent skip)" \
  'bun.*required|required.*bun' "$out2"
assert_grep "bun absent (selected): gives an install instruction" \
  'Install it first|install manually|install via|bun.sh|brew|re-run' "$out2"
# FAIL CLOSED: the gate runs before the build mkdir, so no profile dir / no rc block.
[ -e "$PROFILE2" ] && fail "bun absent (selected): profile dir NOT created" "it exists at $PROFILE2" \
                   || pass "bun absent (selected): profile dir NOT created"
assert_nlit "bun absent (selected): no alias block written to rc" \
  ">>> aka-claude-tools managed: aka" "$RC2"

# ── 2b: command-guard NOT selected + bun absent → success (bun not needed) ────
SB2B="$(sandbox)"
RC2B="$SB2B/.bashrc"; touch "$RC2B"
PROFILE2B="$SB2B/.claude-aka"
STUB2B="$SB2B/stubbin"
make_stub_path "$STUB2B" bun
out2b="$SB2B/install.log"
S2B="$PROFILE2B/settings.json"

SEL2B="secure-settings leak-guard wrap-up shell-audit"
env -i PATH="$STUB2B" HOME="$SB2B" SHELL=/bin/bash CT_ADDITIONS="$SEL2B" \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$out2b" 2>&1
rc2b=$?

assert_ok   "bun absent + command-guard NOT selected: install exits 0" \
  bash -c "[ '$rc2b' -eq 0 ]"
assert_file "bun absent (deselected): profile dir created" "$PROFILE2B"
assert_ok   "bun absent (deselected): settings.json is valid JSON" jq -e . "$S2B"
# command-guard is absent because not selected — and crucially NOT required.
[ -e "$PROFILE2B/hooks/command-guard.ts" ] \
  && fail "bun absent (deselected): command-guard.ts NOT placed" "it exists" \
  || pass "bun absent (deselected): command-guard.ts NOT placed"
# leak-guard (selected, non-bun) still placed AND registered — fully protected.
assert_file "bun absent (deselected): leak-guard.sh still placed" "$PROFILE2B/hooks/leak-guard.sh"
assert_ok   "bun absent (deselected): leak-guard registered" \
  bash -c "jq -e '[.hooks.PreToolUse[]?.hooks[]?.command // empty] | any(.[]; test(\"leak-guard.sh\"))' '$S2B' >/dev/null"
# the rest of the install is unaffected.
assert_ok   "bun absent (deselected): kit denies still merged (secure-settings)" \
  bash -c "jq -e '((.permissions.deny // []) | length) > 0' '$S2B' >/dev/null"
assert_file "bun absent (deselected): wrap-up.md still placed"   "$PROFILE2B/commands/wrap-up.md"
assert_file "bun absent (deselected): shell-audit skill placed"  "$PROFILE2B/skills/shell-audit"
assert_lit  "bun absent (deselected): managed alias block written to rc" \
  ">>> aka-claude-tools managed: aka" "$RC2B"
# no maintainer-only $comment leak in the merged settings.
assert_ok   "bun absent (deselected): no \$comment keys in deployed settings" \
  bash -c "jq -e '[.. | objects | keys[]] | index(\"\$comment\") | not' '$S2B' >/dev/null"

t_summary
