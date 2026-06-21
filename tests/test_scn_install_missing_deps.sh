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
# CASE 2 — bun ABSENT (jq present) → command-guard skipped, rest installs (graceful)
# ════════════════════════════════════════════════════════════════════════════
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

# Select command-guard PLUS a representative non-bun addition set, so we can prove
# command-guard alone is dropped while the rest survives. (CT_ADDITIONS bypasses the
# /dev/tty menu — the only way to drive a deterministic non-interactive selection.)
SEL2="secure-settings leak-guard command-guard wrap-up shell-audit"
env -i PATH="$STUB2" HOME="$SB2" SHELL=/bin/bash CT_ADDITIONS="$SEL2" \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$out2" 2>&1
rc2=$?

assert_ok   "bun absent: install still exits 0 (graceful degradation)" \
  bash -c "[ '$rc2' -eq 0 ]"
assert_file "bun absent: profile dir created" "$PROFILE2"
assert_grep "bun absent: install reported done" 'Done|ready' "$out2"
assert_ok   "bun absent: settings.json is valid JSON" jq -e . "$PROFILE2/settings.json"

# ── command-guard is dropped LOUDLY ─────────────────────────────────────────────
S2="$PROFILE2/settings.json"
# The .ts artifact must NOT be placed when its runtime is missing.
[ -e "$PROFILE2/hooks/command-guard.ts" ] \
  && fail "bun absent: command-guard.ts NOT placed" "it exists" \
  || pass "bun absent: command-guard.ts NOT placed"
# command-guard must NOT be registered in settings hooks.
assert_ok   "bun absent: command-guard NOT registered in PreToolUse" \
  bash -c "jq -e '[.hooks.PreToolUse[]?.hooks[]?.command // empty] | any(.[]; test(\"command-guard\")) | not' '$S2' >/dev/null"
# The skip must be EXPLICIT (loud warning), not silent.
assert_grep "bun absent: warns command-guard NOT enabled" \
  'command-guard NOT enabled|bun.*missing|missing.*bun' "$out2"

# ── the rest of the install is unaffected ────────────────────────────────────
# secure-settings denies were merged.
assert_ok   "bun absent: kit denies still merged (secure-settings unaffected)" \
  bash -c "jq -e '((.permissions.deny // []) | length) > 0' '$S2' >/dev/null"
# leak-guard (a non-bun hook) still placed AND registered.
assert_file "bun absent: leak-guard.sh still placed" "$PROFILE2/hooks/leak-guard.sh"
assert_ok   "bun absent: leak-guard still registered" \
  bash -c "jq -e '[.hooks.PreToolUse[]?.hooks[]?.command // empty] | any(.[]; test(\"leak-guard.sh\"))' '$S2' >/dev/null"
# wrap-up command + shell-audit skill still placed.
assert_file "bun absent: wrap-up.md still placed"     "$PROFILE2/commands/wrap-up.md"
assert_file "bun absent: shell-audit skill placed"    "$PROFILE2/skills/shell-audit"
# alias block still written (install completed).
assert_lit  "bun absent: managed alias block written to rc" \
  ">>> aka-claude-tools managed: aka" "$RC2"
# no maintainer-only $comment leak in the merged settings.
assert_ok   "bun absent: no \$comment keys in deployed settings" \
  bash -c "jq -e '[.. | objects | keys[]] | index(\"\$comment\") | not' '$S2' >/dev/null"

t_summary
