#!/usr/bin/env bash
# Scenario (scn_alias_resolve_edges): UNIT — alias_target_elsewhere must resolve a
# launcher alias's CLAUDE_CONFIG_DIR target through the two real-world rc styles that
# a shallow extractor used to mangle (both surfaced on a live fleet rc):
#
#   1. $VAR / ${VAR}-built target — `alias cc='CLAUDE_CONFIG_DIR="$CC_FLEET_DIR" …'`,
#      where CC_FLEET_DIR is assigned elsewhere in the rc source graph. A direct
#      `export VAR=…` must win over a conditional `: "${VAR:=default}"` default, and
#      the value's own `$HOME` must then expand. (Before: returned the literal
#      `${CC_FLEET_DIR}`.)
#   2. backslash-escaped quotes — `alias x="CLAUDE_CONFIG_DIR=\"\$HOME/.claude-x\" …"`,
#      whose extracted RHS arrives as `\"\$HOME/.claude-x\"`. (Before: returned `\`.)
#
# Plus the unchanged invariants: a NON-launcher alias → OTHER; an undefined name →
# empty; our own managed block for the queried name is ignored (empty).
#
# These feed setup_alias's collision logic, so a mis-resolved target would either
# clobber a user's alias or wrongly claim "already resolves to this profile".
#
# Fully sandboxed: fake $HOME + fake rc; sources common.sh and calls the function
# directly. Never touches a real ~/.claude*.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_alias_resolve_edges:"

# shellcheck source=../shared/lib/common.sh
source "$REPO_ROOT/shared/lib/common.sh"

SB="$(sandbox)"
export HOME="$SB"
RC="$SB/.zshrc"
FLEET="$SB/.aliases"

# Fleet file (sourced from the rc) holds the launcher aliases + a CONDITIONAL default
# for CC_FLEET_DIR that must LOSE to the direct export in the rc.
cat > "$FLEET" <<'EOF'
: "${CC_FLEET_DIR:=$HOME/.claude}"
alias cc='CLAUDE_CONFIG_DIR="$CC_FLEET_DIR" CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 claude'
alias akal="CLAUDE_CONFIG_DIR=\"\$HOME/.claude-aka\" ANTHROPIC_BASE_URL=http://x claude --bare"
alias notlaunch='cd ~/work && git status'
EOF

# rc: the DIRECT export (must win over the := default) + sources the fleet file +
# our own managed block for `cc` (must be ignored when we query `cc`).
cat > "$RC" <<EOF
export CC_FLEET_DIR="\$HOME/.claude-clean"
source $FLEET
# >>> aka-claude-tools managed: ownblk >>>
alias ownblk='CLAUDE_CONFIG_DIR="\$HOME/.claude-ownblk" claude'
# <<< aka-claude-tools managed: ownblk <<<
EOF

# 1. $VAR-built target resolves, direct export beats the := default, $HOME expands.
got="$(alias_target_elsewhere cc "$RC")"
assert_eq "var-built target resolves to the directly-exported dir (not the := default)" \
  "$SB/.claude-clean" "$got"

# 2. backslash-escaped double-quoted target resolves cleanly (no stray backslash).
got="$(alias_target_elsewhere akal "$RC")"
assert_eq "escaped-quote target resolves to the real dir" \
  "$SB/.claude-aka" "$got"

# 3. a non-launcher alias is reported as OTHER, not a path.
got="$(alias_target_elsewhere notlaunch "$RC")"
assert_eq "non-launcher alias → OTHER" "OTHER" "$got"

# 4. an undefined alias name → empty.
got="$(alias_target_elsewhere nosuchalias "$RC")"
assert_eq "undefined alias → empty" "" "$got"

# 5. our OWN managed block for the queried name is stripped → empty (so we never
#    treat a block we wrote as a pre-existing foreign collision).
got="$(alias_target_elsewhere ownblk "$RC")"
assert_eq "own managed block ignored for its own name → empty" "" "$got"

# ── prefix-collision: a var whose name is a PREFIX of another in the same target ──
# $CC must not clobber $CC_FLEET_DIR's prefix during bare-form substitution.
SB2="$(sandbox)"; export HOME="$SB2"; RC2="$SB2/.zshrc"
cat > "$RC2" <<EOF
export CC="\$HOME/.claude-cc"
export CC_FLEET_DIR="\$HOME/.claude-clean"
alias both='CLAUDE_CONFIG_DIR="\$CC_FLEET_DIR" SOMEFLAG="\$CC" claude'
EOF
got="$(alias_target_elsewhere both "$RC2")"
assert_eq "prefix var (\$CC) does not clobber the longer \$CC_FLEET_DIR" \
  "$SB2/.claude-clean" "$got"

# ── source-before-export: parent rc re-assigns the var AFTER sourcing a file that ──
# also assigns it. The user's top-level rc is authoritative → its value wins.
SB3="$(sandbox)"; export HOME="$SB3"; RC3="$SB3/.zshrc"; FLEET3="$SB3/.aliases"
cat > "$FLEET3" <<'EOF'
export CC_FLEET_DIR="$HOME/.claude-fleetdefault"
alias cc='CLAUDE_CONFIG_DIR="$CC_FLEET_DIR" claude'
EOF
cat > "$RC3" <<EOF
source $FLEET3
export CC_FLEET_DIR="\$HOME/.claude-myoverride"
EOF
got="$(alias_target_elsewhere cc "$RC3")"
assert_eq "parent-rc assignment wins over a sourced file's (source-before-export)" \
  "$SB3/.claude-myoverride" "$got"

t_summary
