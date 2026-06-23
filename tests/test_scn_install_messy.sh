#!/usr/bin/env bash
# Scenario T8 — INSTALL/messy: layer over a RICH, hand-built user profile.
#
# Models a power user who already lives in their Claude config and has accreted a
# lot of their OWN state (inspired by a real ~/.claude): MANY unmarked user hooks
# (including a TypeScript .hook.ts hook), custom permission allow/deny rules the
# kit never ships, top-level keys the kit knows nothing about ($schema, _docs,
# sshConfigs, allowedHttpHookUrls), and hook commands wired to ABSOLUTE
# /opt/homebrew/bin/bun paths. Re-pointing the installer at that dir under
# --defaults must LAYER IN PLACE and:
#   • NEVER clobber an unmarked user hook FILE (the .hook.ts and the .sh ones) —
#     the self-clean only touches files carrying the managed marker.
#   • keep every unmarked user hook REGISTRATION (incl. the absolute-bun command).
#   • UNION permissions — every user allow/deny survives AND kit denies are added.
#   • PRESERVE unknown top-level keys verbatim ($schema, _docs, sshConfigs,
#     allowedHttpHookUrls) — a deep-merge keeps what the kit doesn't touch.
#   • layer-in-place, NOT rebuild (no .claude-aka.backup-* dir).
#   • strip maintainer-only "$comment" keys; result is valid JSON.
#
# Fully sandboxed: fake $HOME, fake bash rc, --no-auth-inherit. Never touches a
# real ~/.claude*. Deterministic recommended subset (no optional runtime).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_install_messy:"

SB="$(sandbox)"; touch "$SB/.bashrc"
P="$SB/.claude-aka"                       # default config dir under --defaults
mkdir -p "$P/hooks"

# ── user's OWN unmarked hook FILES (none carry the managed marker) ─────────────
# (a) a plain shell hook.
U_SH="$P/hooks/my-guard.sh"
printf '#!/usr/bin/env bash\necho USER_SH_HOOK\n' > "$U_SH"; chmod +x "$U_SH"
# (b) a TypeScript .hook.ts hook (the modern Claude Code TS hook shape).
U_TS="$P/hooks/format.hook.ts"
printf '// user TS hook\nexport default async () => { console.log("USER_TS_HOOK"); };\n' > "$U_TS"
# (c) a second shell hook invoked via an ABSOLUTE homebrew bun path.
U_BUNHOOK="$P/hooks/lint.ts"
printf '// user bun-run hook\nconsole.log("USER_BUN_HOOK");\n' > "$U_BUNHOOK"
ABS_BUN="/opt/homebrew/bin/bun"
U_BUN_CMD="$ABS_BUN $U_BUNHOOK"

# A pre-existing unrelated user data file — must not be touched.
echo "# my own global memory" > "$P/CLAUDE.md"

# ── user's OWN settings.json — rich and hand-built ────────────────────────────
# Custom perms the kit never ships, unmarked hook registrations (incl. the
# absolute-bun command), AND unknown top-level keys the kit must pass through.
U_DENY='Read(//Users/me/private/**)'
U_ALLOW='Bash(mytool:*)'
U_ALLOW2='WebFetch(domain:internal.example.com)'
cat > "$P/settings.json" <<JSON
{
  "\$schema": "https://json.schemastore.org/claude-code-settings.json",
  "_docs": "my personal notes about this config",
  "theme": "dark",
  "sshConfigs": { "prod": "ssh -i ~/.ssh/prod_key user@prod" },
  "allowedHttpHookUrls": ["https://hooks.example.com/notify"],
  "permissions": {
    "deny":  ["$U_DENY"],
    "allow": ["$U_ALLOW", "$U_ALLOW2"]
  },
  "hooks": {
    "PreToolUse": [
      {"matcher":"Bash","hooks":[{"type":"command","command":"$U_SH"}]},
      {"matcher":"Write|Edit","hooks":[{"type":"command","command":"$U_TS"}]},
      {"matcher":"Edit","hooks":[{"type":"command","command":"$U_BUN_CMD"}]}
    ]
  }
}
JSON
assert_ok "seed messy settings is valid JSON" jq -e . "$P/settings.json"

# Deterministic recommended subset that needs no optional runtime (bun/rtk/
# trufflehog): leak-guard ships a marked kit hook + registration; secure-settings
# ships kit denies to union against the user's own.
SEL="secure-settings leak-guard"
CT_ADDITIONS="$SEL" SHELL=/bin/bash HOME="$SB" \
  bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log" 2>&1
rc=$?

S="$P/settings.json"
assert_eq   "install exits 0 over a messy profile" "0" "$rc"
assert_file "profile dir still present"            "$P"
assert_ok   "settings.json still valid JSON"       jq -e . "$S"

# ── layer-in-place, NOT rebuild ───────────────────────────────────────────────
n_bak=$(find "$SB" -maxdepth 1 -type d -name '.claude-aka.backup-*' 2>/dev/null | wc -l | tr -d ' ')
assert_eq   "no rebuild backup created (layered in place)" "0" "$n_bak"

# ── unmarked user hook FILES never clobbered ──────────────────────────────────
assert_file "user .sh hook file kept"     "$U_SH"
assert_file "user .hook.ts hook file kept" "$U_TS"
assert_file "user bun-run hook file kept"  "$U_BUNHOOK"
assert_grep "user .sh hook body intact"    'USER_SH_HOOK'  "$U_SH"
assert_grep "user .hook.ts body intact"    'USER_TS_HOOK'  "$U_TS"
# pre-existing user data untouched.
assert_file "pre-existing CLAUDE.md kept"  "$P/CLAUDE.md"
assert_grep "CLAUDE.md content intact"     'my own global memory' "$P/CLAUDE.md"

# ── unmarked user hook REGISTRATIONS kept (incl. absolute-bun command) ─────────
assert_ok "user .sh hook registration kept" \
  bash -c "jq -e --arg c '$U_SH' '[.hooks.PreToolUse[]?.hooks[].command] | index(\$c) != null' '$S' >/dev/null"
assert_ok "user .hook.ts registration kept" \
  bash -c "jq -e --arg c '$U_TS' '[.hooks.PreToolUse[]?.hooks[].command] | index(\$c) != null' '$S' >/dev/null"
assert_ok "user absolute-bun hook registration kept verbatim" \
  bash -c "jq -e --arg c '$U_BUN_CMD' '[.hooks.PreToolUse[]?.hooks[].command] | index(\$c) != null' '$S' >/dev/null"
assert_lit "absolute /opt/homebrew/bin/bun path survives in settings" \
  "$ABS_BUN" "$S"

# ── permissions UNIONED (user rules survive AND kit denies added) ─────────────
assert_ok "user deny preserved (union)" \
  bash -c "jq -e --arg r '$U_DENY' '.permissions.deny | index(\$r) != null' '$S' >/dev/null"
assert_ok "user allow preserved (union)" \
  bash -c "jq -e --arg r '$U_ALLOW' '.permissions.allow | index(\$r) != null' '$S' >/dev/null"
assert_ok "second user allow preserved (union)" \
  bash -c "jq -e --arg r '$U_ALLOW2' '.permissions.allow | index(\$r) != null' '$S' >/dev/null"
KIT_DENY="$(jq -r '.permissions.deny[0]' "$REPO_ROOT/config/settings.base.json")"
assert_ok "kit deny adopted alongside user rules (union added kit set)" \
  bash -c "jq -e --arg r '$KIT_DENY' '.permissions.deny | index(\$r) != null' '$S' >/dev/null"

# ── unknown top-level keys preserved verbatim ─────────────────────────────────
assert_ok "user \$schema key preserved" \
  bash -c "jq -e 'has(\"\$schema\")' '$S' >/dev/null"
assert_ok "user _docs key preserved" \
  bash -c "jq -e '._docs == \"my personal notes about this config\"' '$S' >/dev/null"
assert_ok "user theme preserved" \
  bash -c "jq -e '.theme == \"dark\"' '$S' >/dev/null"
assert_ok "user sshConfigs key preserved verbatim" \
  bash -c "jq -e '.sshConfigs.prod | startswith(\"ssh -i\")' '$S' >/dev/null"
assert_ok "user allowedHttpHookUrls key preserved" \
  bash -c "jq -e '.allowedHttpHookUrls | index(\"https://hooks.example.com/notify\") != null' '$S' >/dev/null"

# ── kit hook still landed + registered (the install actually layered) ──────────
assert_file "kit hook placed: leak-guard.ts" "$P/hooks/leak-guard.ts"
assert_ok   "leak-guard registered in settings.PreToolUse" \
  bash -c "jq -e '[.hooks.PreToolUse[]?.hooks[].command] | any(.[]; endswith(\"/leak-guard.ts\"))' '$S' >/dev/null"

# ── no maintainer-only \$comment leak ─────────────────────────────────────────
assert_ok "no \$comment keys in layered settings" \
  bash -c "jq -e '[.. | objects | keys[]] | index(\"\$comment\") | not' '$S' >/dev/null"

# ── no duplicate PreToolUse registrations (union must dedupe, not double) ──────
n_tot=$(jq '.hooks.PreToolUse | length' "$S")
n_uniq=$(jq '.hooks.PreToolUse | unique_by(tojson) | length' "$S")
assert_eq "no duplicate PreToolUse registrations after layer" "$n_tot" "$n_uniq"

# Install reported success.
assert_grep "install reported done" 'Done|ready' "$SB/log"

t_summary
