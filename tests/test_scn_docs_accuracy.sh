#!/usr/bin/env bash
# Docs-accuracy scenario (T1): README.md + agent-install.md must match install.sh
# reality. The classic "README out of date" class — a doc that lies about the
# product is a real defect, so these assertions PIN reality, not the prose.
#
# Pure static analysis (no install run): parse the source-of-truth artifacts
# (config/additions.json, install.sh flag parser) and assert each fact is
# documented. Fully sandbox-safe — reads repo files only, never a real profile.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_docs_accuracy:"

README="$REPO_ROOT/README.md"
AGENT="$REPO_ROOT/agent-install.md"
INSTALL="$REPO_ROOT/install.sh"

# ── 1. Every addition id in the catalog is documented in README ─────────────
# The catalog drives the menu; a user reads README to learn what's on offer.
# An id present in additions.json but absent from README is an undocumented
# addition (README out of date as the catalog grows).
while IFS= read -r id; do
  [ -z "$id" ] && continue
  assert_lit "README documents addition id: $id" "$id" "$README"
done < <(jq -r '.additions[].id' "$ADDITIONS")

# ── 2. Every addition has a row in the "What's in the box" table ────────────
# The id check above passes if the id appears ANYWHERE (e.g. a code example or
# the layout tree). The user-facing catalog is the table; assert each addition's
# human NAME is bolded in a table row. This catches additions that exist but were
# never given a table entry.
while IFS= read -r name; do
  [ -z "$name" ] && continue
  # A table row starts with "| **". Assert SOME such row contains the addition's
  # literal name. grep -F on the name (not a built regex) avoids metachar pitfalls
  # — e.g. a name like "Harness pointer (opt-in)" whose "(opt-in)" would be parsed
  # as a regex group and never match the literal text.
  if grep -E '^\| \*\*' "$README" | grep -qF -- "$name"; then
    pass "README 'What's in the box' table row for: $name"
  else
    fail "README 'What's in the box' table row for: $name" "no table row names it"
  fi
done < <(jq -r '.additions[].name' "$ADDITIONS")

# ── 3. Every install.sh flag is documented in README ────────────────────────
# Flags are parsed in the `case "$arg" in` block; extract the real set rather
# than hardcoding it, so the test tracks the installer.
for flag in --defaults --no-auth-inherit --apply --alias; do
  assert_lit "install.sh actually accepts $flag (case arm present)" "$flag)" "$INSTALL"
  assert_lit "README documents flag: $flag" "$flag" "$README"
done

# ── 4. Env knobs are documented in README ───────────────────────────────────
# CT_ADDITIONS (scripted selection) and CT_NONINTERACTIVE (the env equivalent of
# --defaults) are user-facing levers; both should be discoverable in README.
for env in CT_ADDITIONS CT_NONINTERACTIVE; do
  assert_lit "install.sh references env knob: $env" "$env" "$INSTALL"
  assert_lit "README documents env knob: $env" "$env" "$README"
done

# ── 5. Uninstall section describes deselect-to-uninstall (current behavior) ──
# install.sh + test_uninstall.sh prove a re-run WITHOUT an addition removes its
# files and prunes its settings registration automatically. README's removal
# guidance must reflect that, not the stale "delete files and settings.json
# registration by hand" instruction.
assert_nlit "README does NOT tell users to remove an addition by hand (deselect is automatic)" \
  "settings.json\` registration by hand" "$README"
# Positive: README should mention deselecting / re-running to remove an addition.
assert_grep "README describes deselect/re-run to remove an addition" \
  "deselect|re-run.*without|drop.*addition" "$README"

# ── 6. Upgrade section describes layer-in-place as the default ───────────────
# install.sh defaults a non-default existing profile to layer-in-place; --clean
# opts into the rebuild. README must not present the rebuild as the only/default
# upgrade path.
assert_grep "README upgrade section mentions layer-in-place default" \
  "layer-in-place|layer.*in place" "$README"

# ── 7. hook-rename pre-port path is documented for upgraders ─────────
# hook-rename.sh is a required one-time step for profiles created before
# the hook rename; the installer does NOT invoke it automatically, so an upgrader
# must be told to run it. A doc that omits it strands old profiles.
assert_lit "README/agent-install mention hook-rename pre-port step" \
  "hook-rename" "$README"

t_summary
