#!/usr/bin/env bash
# Scenario — the --apply DETERMINISTIC ENGINE (install.sh apply_additions).
#
# --apply is the repeatable mechanics entry point: given CT_CONFIG_DIR +
# CT_ADDITIONS it layers exactly those additions onto the dir and exits — no
# prompts, no migration, no alias, no auth. It is what Path A (agent-install.md)
# invokes AFTER doing the judgment work (scan + migrate the user's config), and
# what a scripted/CI fresh install uses. This pins that contract.
#
# Invariants asserted:
#   A. Fresh apply onto an empty dir places files + writes one valid settings.json,
#      registers leak-guard TWICE, wires the statusline, never leaks $comment.
#   B. Apply onto a dir that already has a (migrated) settings.json UNIONS the kit
#      onto it: the user's own rules survive, a kit rule the version retired is
#      pruned, and a re-run is idempotent (no drift) — the repeatability guarantee.
#   C. Input guards: missing CT_CONFIG_DIR or UNSET CT_ADDITIONS fails loudly.
#
# Fully sandboxed: fake $HOME, --no-auth-inherit, never touches a real ~/.claude*.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_apply_engine:"

INSTALL="$REPO_ROOT/install.sh"
PERMS="$REPO_ROOT/config/managed-permissions.json"
# Deterministic subset needing no optional runtime (bun/rtk/trufflehog) so CI is stable.
SEL="secure-settings leak-guard wrap-up shell-audit statusline"

# ── A. fresh apply onto an empty dir ─────────────────────────────────────────
SB="$(sandbox)"; DIR="$SB/.claude-aka"
CT_CONFIG_DIR="$DIR" CT_ADDITIONS="$SEL" HOME="$SB" \
  bash "$INSTALL" --apply --no-auth-inherit >"$SB/log" 2>&1
assert_eq   "--apply exits 0 on a fresh dir" "0" "$?"

S="$DIR/settings.json"
assert_ok   "settings.json is valid JSON" jq -e . "$S"
assert_file "leak-guard.sh placed"  "$DIR/hooks/leak-guard.sh"
assert_file "wrap-up.md placed"    "$DIR/commands/wrap-up.md"
assert_file "shell-audit skill placed" "$DIR/skills/shell-audit"
assert_file "statusline.ts placed" "$DIR/hooks/statusline.ts"
assert_ok   "leak-guard registered ONCE (web tools only; Bash is command-guard's)" \
  bash -c "jq -e '[.hooks.PreToolUse[]?.hooks[].command]|map(select(endswith(\"/leak-guard.sh\")))|length==1' '$S' >/dev/null"
assert_ok   "kit denies present (secure-settings landed)" \
  bash -c "jq -e '((.permissions.deny // [])|length) > 0' '$S' >/dev/null"
assert_ok   "statusLine wired" \
  bash -c "jq -e '(.statusLine.command // \"\")|endswith(\"/statusline.ts\")' '$S' >/dev/null"
assert_ok   "no \$comment maintainer leak" \
  bash -c "jq -e '[.. | objects | keys[]?]|index(\"\$comment\")|not' '$S' >/dev/null"
# Engine mode is chrome-free: no interactive banner.
assert_ngrep "no installer banner in --apply output" 'aka-claude-tools installer' "$SB/log"

# ── B. apply onto an existing (migrated) settings.json ───────────────────────
# Model what Path A does: it migrates the user's settings.json into <dir> first,
# THEN calls --apply to union the additions on top. Seed a user-owned deny plus a
# rule the kit has RETIRED (in managed-permissions .retired) — the union must keep
# the first and the reconcile must drop the second.
SB2="$(sandbox)"; DIR2="$SB2/.claude-aka"; mkdir -p "$DIR2"
USER_DENY='Read(//Users/me/secret/**)'
RETIRED="$(jq -r '(.retired.deny // [])[0] // empty' "$PERMS")"
jq -n --arg u "$USER_DENY" --arg r "$RETIRED" \
  '{permissions:{deny:( [$u] + (if $r=="" then [] else [$r] end) )}, theme:"dark"}' \
  > "$DIR2/settings.json"

CT_CONFIG_DIR="$DIR2" CT_ADDITIONS="secure-settings leak-guard" HOME="$SB2" \
  bash "$INSTALL" --apply --no-auth-inherit >"$SB2/log" 2>&1
assert_eq   "--apply exits 0 onto a migrated settings.json" "0" "$?"

S2="$DIR2/settings.json"
assert_ok   "user's own cosmetic key (theme) preserved" \
  bash -c "jq -e '.theme == \"dark\"' '$S2' >/dev/null"
assert_ok   "user's own deny rule preserved (union never drops it)" \
  bash -c "jq -e '(.permissions.deny // [])|index(\"$USER_DENY\") != null' '$S2' >/dev/null"
assert_ok   "kit denies unioned in (more than the user's lone rule)" \
  bash -c "jq -e '((.permissions.deny // [])|length) > 1' '$S2' >/dev/null"
if [ -n "$RETIRED" ]; then
  assert_ok "kit-retired rule pruned by reconcile" \
    bash -c "jq -e '(.permissions.deny // [])|index(\"$RETIRED\") == null' '$S2' >/dev/null"
fi

# Idempotent: a second --apply with the same selection must not drift.
cp "$S2" "$SB2/first.json"
CT_CONFIG_DIR="$DIR2" CT_ADDITIONS="secure-settings leak-guard" HOME="$SB2" \
  bash "$INSTALL" --apply --no-auth-inherit >"$SB2/log2" 2>&1
assert_ok   "re-run is idempotent (no settings drift)" \
  bash -c "diff <(jq -S . '$SB2/first.json') <(jq -S . '$S2') >/dev/null"

# ── B2. config_dir canonicalization invariant (load-bearing for the statusline deselect
#    anchor: install and deselect must normalize the dir IDENTICALLY, else the quoted
#    full-path tail won't match). Install statusline with a TRAILING-SLASH CT_CONFIG_DIR,
#    then deselect with NO trailing slash — the kit statusLine must still prune. A future
#    refactor that normalizes the two paths differently fails HERE. (Needs bun, which the
#    suite already preflights.) ──
SB4="$(sandbox)"; DIR4="$SB4/.claude-aka"
CT_CONFIG_DIR="$DIR4/" CT_ADDITIONS="statusline leak-guard" HOME="$SB4" \
  bash "$INSTALL" --apply --no-auth-inherit >"$SB4/log" 2>&1
S4="$DIR4/settings.json"
assert_ok   "statusLine registered (install via trailing-slash dir)" \
  bash -c "jq -e '.statusLine.command' '$S4' >/dev/null"
CT_CONFIG_DIR="$DIR4" CT_ADDITIONS="leak-guard" HOME="$SB4" \
  bash "$INSTALL" --apply --no-auth-inherit >"$SB4/log2" 2>&1
assert_ok   "statusLine pruned on deselect despite install/deselect slash mismatch" \
  bash -c "jq -e 'has(\"statusLine\") | not' '$S4' >/dev/null"

# ── C. input guards ──────────────────────────────────────────────────────────
SB3="$(sandbox)"; DIR3="$SB3/.claude-aka"
assert_fail "--apply without CT_CONFIG_DIR fails" \
  env -u CT_CONFIG_DIR HOME="$SB3" bash "$INSTALL" --apply --no-auth-inherit
# CT_ADDITIONS UNSET (not just empty) must fail — empty is a valid "select none".
assert_fail "--apply with UNSET CT_ADDITIONS fails" \
  env -u CT_ADDITIONS CT_CONFIG_DIR="$DIR3" HOME="$SB3" bash "$INSTALL" --apply --no-auth-inherit

t_summary
