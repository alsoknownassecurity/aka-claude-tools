#!/usr/bin/env bash
# Scenario T9 — INSTALL/messy: an existing settings.json carries DANGEROUS flags.
#
# Models a user whose profile already runs Claude without permission prompts:
#   permissions.defaultMode = "bypassPermissions"
#   skipAutoPermissionPrompt = true
#   skipDangerousModePermissionPrompt = true
# These three flags neuter the permission system entirely — bypassPermissions
# ignores the deny rules the kit installs, and the skip-prompt flags suppress the
# safety prompts. The kit's WHOLE pitch is "secure defaults", so when it touches
# a profile carrying these, the design (install.sh ~L564-580) is: SURFACE them and
# offer to strip, KEEP-by-default only when the user is interactively asked. The
# kit's own template never adds them.
#
# This probe pins the behavior across the THREE ways install.sh can meet a
# dangerous-flag profile non-interactively (the only mode a sandbox can drive —
# every prompt reads /dev/tty, see common.sh prompt()/confirm()):
#   A) FRESH non-default install (target .claude-aka does not exist) — the kit
#      builds a clean profile; an UNRELATED ~/.claude with dangerous flags must
#      NOT bleed in, and the new profile must be prompt-safe.
#   B) IN-PLACE layering onto an EXISTING .claude-aka that already carries the
#      flags — this is the common "re-point the installer at my profile" upgrade.
#      The kit layers its 38 deny rules on top; a security tool MUST NOT silently
#      leave bypassPermissions in force (it makes those very denies inert).
#   C) the deployed result is always valid JSON and free of $comment leaks.
#
# EXPECTED behavior is encoded as the assertions. Where the installer's current
# behavior diverges (it does NOT surface/handle the flags on the in-place upgrade
# path — the surfacing logic lives only in the migrate-from-a-SEPARATE-source
# branch, unreachable here), the assertion pins the SECURE expectation and the
# divergence is reported as a finding, not fixed.
#
# Limitation: the migrate-from-separate-source surfacing branch (the only place
# the kit asks "keep bypassPermissions?") is gated behind interactive /dev/tty
# confirms that a sandbox cannot reach without a pty; it is documented in the
# summary rather than asserted here.
#
# Fully sandboxed: fake $HOME, fake bash rc, --no-auth-inherit. Never touches a
# real ~/.claude*. Deterministic recommended subset (no optional runtime).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_install_dangerous_flags:"

# secure-settings ships the kit's deny set (its safe baseline); no optional runtime.
SEL="secure-settings"
DANGER_JSON='{ "permissions": { "defaultMode": "bypassPermissions", "allow": ["Bash(ls:*)"], "deny": [] }, "skipAutoPermissionPrompt": true, "skipDangerousModePermissionPrompt": true }'

# ──────────────────────────────────────────────────────────────────────────────
# (A) FRESH non-default install — an UNRELATED ~/.claude carries dangerous flags.
#     The kit creates .claude-aka from scratch; under --defaults it does NOT
#     migrate (migrate confirm defaults N with no rebuild), so the dangerous flags
#     must NOT appear in the new profile, and ~/.claude must be left untouched.
# ──────────────────────────────────────────────────────────────────────────────
SB="$(sandbox)"; touch "$SB/.bashrc"
mkdir -p "$SB/.claude"
printf '%s\n' "$DANGER_JSON" > "$SB/.claude/settings.json"
P="$SB/.claude-aka"

CT_ADDITIONS="$SEL" SHELL=/bin/bash HOME="$SB" \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log" 2>&1
rcA=$?
SA="$P/settings.json"

assert_eq   "A: fresh install exits 0"        "0" "$rcA"
assert_file "A: new profile settings created" "$SA"
assert_ok   "A: new profile settings valid JSON" jq -e . "$SA"

# The new profile must be prompt-SAFE: none of the three dangerous flags.
assert_ok   "A: fresh profile has NO bypassPermissions defaultMode" \
  bash -c "jq -e '(.permissions.defaultMode // \"\") != \"bypassPermissions\"' '$SA' >/dev/null"
assert_ok   "A: fresh profile has NO skipAutoPermissionPrompt=true" \
  bash -c "jq -e '(.skipAutoPermissionPrompt // false) != true' '$SA' >/dev/null"
assert_ok   "A: fresh profile has NO skipDangerousModePermissionPrompt=true" \
  bash -c "jq -e '(.skipDangerousModePermissionPrompt // false) != true' '$SA' >/dev/null"

# The unrelated ~/.claude must be untouched (its flags are the user's other profile).
assert_grep "A: unrelated ~/.claude still has its own flag (untouched)" \
  'bypassPermissions' "$SB/.claude/settings.json"

# ──────────────────────────────────────────────────────────────────────────────
# (B) IN-PLACE layering onto an EXISTING .claude-aka that ALREADY carries the
#     dangerous flags. This is the common re-point/upgrade. Under --defaults an
#     existing non-default target is layered in place (no rebuild). EXPECTED of a
#     security tool: it must NOT silently leave the permission system disabled —
#     after layering its deny set on top, bypassPermissions + the skip-prompt
#     flags must be NEUTRALIZED (or, at minimum, the run must SURFACE them so the
#     user is not left unknowingly prompt-free).
# ──────────────────────────────────────────────────────────────────────────────
SB2="$(sandbox)"; touch "$SB2/.bashrc"
P2="$SB2/.claude-aka"
mkdir -p "$P2"
printf '%s\n' "$DANGER_JSON" > "$P2/settings.json"
assert_ok "B: seed in-place dangerous settings is valid JSON" jq -e . "$P2/settings.json"

CT_ADDITIONS="$SEL" SHELL=/bin/bash HOME="$SB2" \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB2/log" 2>&1
rcB=$?
SB_S="$P2/settings.json"

assert_eq   "B: in-place layer exits 0"           "0" "$rcB"
assert_ok   "B: layered settings still valid JSON" jq -e . "$SB_S"

# Prove the kit actually layered (its deny set landed) — so this IS the upgrade
# path, not a no-op. If this fails the rest is meaningless.
KIT_DENY="$(jq -r '.permissions.deny[0]' "$REPO_ROOT/config/settings.base.json")"
assert_ok   "B: kit deny rules layered onto the existing profile" \
  bash -c "jq -e --arg r '$KIT_DENY' '.permissions.deny | index(\$r) != null' '$SB_S' >/dev/null"

# DECISION (operator, "warn always, never strip"): the kit does NOT strip the user's
# dangerous flags — they are the user's call — but it must never let them sit
# SILENTLY, since bypassPermissions makes the deny rules it just layered inert. So the
# invariant on this path is: the flags are KEPT, and a heads-up is surfaced on EVERY
# path (including --defaults / non-interactive).
assert_ok   "B: bypassPermissions kept (kit never strips the user's flag)" \
  bash -c "jq -e '(.permissions.defaultMode // \"\") == \"bypassPermissions\"' '$SB_S' >/dev/null"
assert_ok   "B: skip-prompt flags kept (kit never strips them)" \
  bash -c "jq -e '(.skipAutoPermissionPrompt == true) and (.skipDangerousModePermissionPrompt == true)' '$SB_S' >/dev/null"

# The kept flags must NOT be silent: the installer surfaces a heads-up so the user
# knows the kit's deny rules are inert while the flags are set (the always-on warn).
assert_grep "B: install surfaces a heads-up about the dangerous flags (not silent)" \
  'bypassPermission|skip-prompt|skipDangerous|without permission prompts|Heads-up' "$SB2/log"

# ──────────────────────────────────────────────────────────────────────────────
# (C) cross-cutting hygiene on the layered result: no maintainer-only $comment.
# ──────────────────────────────────────────────────────────────────────────────
assert_ok   "C: no \$comment keys leaked into layered settings" \
  bash -c "jq -e '[.. | objects | keys[]] | index(\"\$comment\") | not' '$SB_S' >/dev/null"

# The user's own non-dangerous allow rule must survive the layer (union), so a
# strip of the dangerous flags doesn't nuke unrelated user config.
assert_ok   "C: user's own benign allow rule preserved through the layer" \
  bash -c "jq -e '.permissions.allow | index(\"Bash(ls:*)\") != null' '$SB_S' >/dev/null"

t_summary
