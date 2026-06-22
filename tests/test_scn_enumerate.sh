#!/usr/bin/env bash
# Scenario — install.sh --enumerate: the host profile↔alias map as JSON.
#
# agent-install Step 1 must see EVERY launcher alias resolved through the rc's whole
# source/. chain (a fleet aliases file the rc sources holds most launchers, so a
# shallow grep of ~/.zshrc under-counts and risks an alias-collision the agent misses).
# The bash-only helpers return empty when sourced into the agent's zsh tool, so the
# enumeration is exposed as a deterministic `install.sh --enumerate` that emits JSON.
#
# Invariants:
#   A. Emits valid JSON: rc, profiles[] (dir+managed+aliases), unresolved_aliases[].
#   B. Resolves launcher aliases through the FULL chain incl. a sourced fleet file and
#      a $VAR-built target; managed-block aliases are included; non-launcher aliases are not.
#   C. managed flag uses the SAME two Step-1 signals (marker file OR a recognized kit hook).
#   D. A launcher alias whose target is no existing profile lands in unresolved_aliases.
#
# Fully sandboxed: fake $HOME, never touches a real ~/.claude*.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_enumerate:"

INSTALL="$REPO_ROOT/install.sh"
SB="$(sandbox)"; export HOME="$SB"

# ── profiles ─────────────────────────────────────────────────────────────────
mkdir -p "$SB/.claude-aka" "$SB/.claude-clean" "$SB/.claude-plain"
# managed via the marker file
printf 'managed=aka-claude-tools\n' > "$SB/.claude-aka/.aka-claude-tools-meta"
# managed via a recognized kit hook in settings.json (no marker)
printf '{"hooks":{"PreToolUse":[{"matcher":"WebSearch","hooks":[{"type":"command","command":"%s/.claude-clean/hooks/leak-guard.sh"}]}]}}\n' "$SB" > "$SB/.claude-clean/settings.json"
# NOT managed: settings present but neither signal
printf '{"model":"opus"}\n' > "$SB/.claude-plain/settings.json"

# ── rc + sourced fleet aliases ───────────────────────────────────────────────
FLEET="$SB/.aliases"
{
  echo 'alias aka='"'"'CLAUDE_CONFIG_DIR="$HOME/.claude-aka" claude'"'"''
  # Escaped-double-quote body (the real-world local-model variant form:
  # alias x="CLAUDE_CONFIG_DIR=\"$HOME/…\" …") — the shared parser must unescape it.
  echo 'alias akal="CLAUDE_CONFIG_DIR=\"$HOME/.claude-aka\" ANTHROPIC_BASE_URL=http://x claude --bare"'
  echo 'alias cc='"'"'CLAUDE_CONFIG_DIR="$CC_FLEET_DIR" claude'"'"''         # $VAR-built target
  echo 'alias pln='"'"'CLAUDE_CONFIG_DIR="$HOME/.claude-plain" claude'"'"''
  echo 'alias gone='"'"'CLAUDE_CONFIG_DIR="$HOME/.claude-gone" claude'"'"''  # dangling target
  echo 'alias notlaunch='"'"'cd ~/work && git status'"'"''                   # NOT a launcher
} > "$FLEET"
RC="$SB/.zshrc"
{
  echo 'export CC_FLEET_DIR="$HOME/.claude-clean"'
  echo "source $FLEET"
  echo '# >>> aka-claude-tools managed: akamgd >>>'
  echo 'alias akamgd='"'"'CLAUDE_CONFIG_DIR="$HOME/.claude-aka" claude'"'"''  # in a managed block
  echo '# <<< aka-claude-tools managed: akamgd <<<'
} > "$RC"

# ── run ──────────────────────────────────────────────────────────────────────
OUT="$SB/out.json"
SHELL=/bin/zsh bash "$INSTALL" --enumerate >"$OUT" 2>"$SB/err"
assert_eq   "--enumerate exits 0" "0" "$?"
assert_ok   "emits valid JSON" jq -e . "$OUT"
assert_ok   "rc points at the sandbox .zshrc" \
  bash -c "jq -e --arg rc '$RC' '.rc==\$rc' '$OUT' >/dev/null"
assert_ok   "exactly 3 profiles enumerated" \
  bash -c "jq -e '.profiles|length==3' '$OUT' >/dev/null"

# B + C: resolution through the chain + managed signals
assert_ok   ".claude-aka managed (marker); aliases aka + akal(escaped-quote body) + akamgd(managed block)" \
  bash -c "jq -e --arg d '$SB/.claude-aka' '.profiles[]|select(.dir==\$d)|.managed==true and (.aliases|sort)==[\"aka\",\"akal\",\"akamgd\"]' '$OUT' >/dev/null"
assert_ok   ".claude-clean managed (kit hook) with the \$VAR-built alias cc" \
  bash -c "jq -e --arg d '$SB/.claude-clean' '.profiles[]|select(.dir==\$d)|.managed==true and (.aliases==[\"cc\"])' '$OUT' >/dev/null"
assert_ok   ".claude-plain NOT managed, alias pln resolves to it" \
  bash -c "jq -e --arg d '$SB/.claude-plain' '.profiles[]|select(.dir==\$d)|.managed==false and (.aliases==[\"pln\"])' '$OUT' >/dev/null"

# D: dangling launcher surfaces; non-launcher excluded entirely
assert_ok   "dangling alias 'gone' in unresolved_aliases" \
  bash -c "jq -e '[.unresolved_aliases[].name]|index(\"gone\")!=null' '$OUT' >/dev/null"
assert_ok   "non-launcher 'notlaunch' appears nowhere" \
  bash -c "jq -e '([.profiles[].aliases[]]+[.unresolved_aliases[].name])|index(\"notlaunch\")==null' '$OUT' >/dev/null"

# ── E. set -euo pipefail robustness: an rc with ZERO launcher aliases must NOT abort
# (grep-no-match returns 1; under pipefail+set -e a naive command-sub would kill the
# whole enumerate). A profile with no alias pointing at it should still enumerate. ──
SB2="$(sandbox)"
mkdir -p "$SB2/.claude"            # a profile, but no alias resolves to it
RC2="$SB2/.zshrc"
{ echo 'export FOO=bar'; echo '# no launcher aliases here at all'; } > "$RC2"
OUT2="$SB2/out.json"
HOME="$SB2" SHELL=/bin/zsh bash "$INSTALL" --enumerate >"$OUT2" 2>"$SB2/err"
assert_eq "no-launcher-alias rc: --enumerate exits 0 (no set -e abort)" "0" "$?"
assert_ok "no-launcher-alias rc: still valid JSON" jq -e . "$OUT2"
assert_ok "no-launcher-alias rc: empty alias sets" \
  bash -c "jq -e '([.profiles[].aliases[]]|length==0) and (.unresolved_aliases|length==0)' '$OUT2' >/dev/null"

t_summary
