#!/usr/bin/env bash
# Rebuild PRESERVES all user content (T21) — the "lose nothing" guarantee.
#
# A power-user profile holds far more than the kit's known structure: a bespoke
# framework dir (myframework/), plugins/, custom top-level JSON, nested hook subdirs, an
# MCP config, CLAUDE.md @-imports. A clean --clean rebuild moves the dir to a
# backup and recreates it; this test proves preserve_from_backup brings ALL of that
# back — while the secret/volatile caches (CT_SECRET_EXCLUDES) stay behind by
# design — and that the complexity advisory points such configs at Path A.
#
# Fully sandboxed: fake $HOME, fake bash rc, --no-auth-inherit; never touches a
# real ~/.claude*.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_rebuild_preserve:"

SB="$(sandbox)"; touch "$SB/.bashrc"
P="$SB/.claude-aka"                          # default target of --defaults
S="$P/settings.json"
SEL="secure-settings leak-guard"
run() { CT_ADDITIONS="$SEL" SHELL=/bin/bash HOME="$SB" \
        bash "$REPO_ROOT/install.sh" "$@" --defaults --no-auth-inherit >"$SB/log" 2>&1; }

# ── (1) baseline install, then layer on a rich user setup ─────────────────────
run; assert_eq "baseline install exits 0" "0" "$?"
assert_file "kit hook present after baseline" "$P/hooks/leak-guard.sh"

# bespoke content the kit's allowlist would NOT know to restore
mkdir -p "$P/myframework/MEMORY" "$P/plugins/marketplaces" "$P/hooks/handlers" "$P/hooks/security"
printf 'my memory\n'      > "$P/myframework/MEMORY/note.md"
printf 'isa\n'           > "$P/ISA.md"
printf '{"limit":1}\n'    > "$P/policy-limits.json"
printf 'plugin\n'         > "$P/plugins/marketplaces/m.json"
printf '// handler\n'     > "$P/hooks/handlers/h.ts"            # nested hook subdir
printf '// sec\n'         > "$P/hooks/security/s.ts"
printf '#!/usr/bin/env bash\n# my own hook (unmarked)\n:\n' > "$P/hooks/myhook.sh"
# signals that should trigger the complexity advisory
printf '# global memory\n@~/shared/agents.md\n' > "$P/CLAUDE.md"
jq '. + {mcpServers:{demo:{command:"x"}}}' "$S" > "$S.tmp" && mv "$S.tmp" "$S"
# the profile's own caches/auth — a rebuild returns a profile's data to ITSELF, so
# these come home too (no secret-spreading; it's the same dir). The user opted to
# migrate everything and leave behind only stale kit cruft.
mkdir -p "$P/shell-snapshots" "$P/paste-cache" "$P/file-history" "$P/session-env" "$P/telemetry"
printf 'shell snapshot\n' > "$P/shell-snapshots/snap.sh"
printf 'pasted text\n'    > "$P/paste-cache/p.txt"
printf 'edit snapshot\n'  > "$P/file-history/f"
printf 'env dump\n'       > "$P/session-env/e"
printf '{"t":1}\n'        > "$P/telemetry/t.json"
printf '{"k":"v"}\n'      > "$P/.credentials.json"

# ── (2) clean rebuild ─────────────────────────────────────────────────────────
run --clean; rc=$?
assert_eq "clean rebuild exits 0" "0" "$rc"
assert_ok "settings.json still valid JSON after rebuild" jq -e . "$S"

bak="$(ls -d "$SB"/.claude-aka.backup-* 2>/dev/null | head -1)"
assert_ok "a timestamped backup was created" test -n "$bak"

# ── (3) ALL bespoke user content preserved into the rebuilt profile ───────────
assert_file "myframework/ framework preserved"        "$P/myframework/MEMORY/note.md"
assert_grep "myframework/ content intact"             'my memory' "$P/myframework/MEMORY/note.md"
assert_file "custom top-level file preserved" "$P/ISA.md"
assert_file "custom JSON preserved"           "$P/policy-limits.json"
assert_file "plugins/ preserved"              "$P/plugins/marketplaces/m.json"
assert_file "nested hook subdir preserved (handlers/)" "$P/hooks/handlers/h.ts"
assert_file "nested hook subdir preserved (security/)" "$P/hooks/security/s.ts"
assert_file "unmarked user hook preserved"    "$P/hooks/myhook.sh"
assert_file "CLAUDE.md preserved"             "$P/CLAUDE.md"
assert_grep "rebuild reported the preserved sweep" 'Preserved [0-9]+ more file' "$SB/log"

# ── (4) the profile's own caches + auth came home (migrate everything) ────────
for c in shell-snapshots/snap.sh paste-cache/p.txt file-history/f session-env/e telemetry/t.json; do
  assert_file "profile cache restored: $c" "$P/$c"
done
assert_file "auth (.credentials.json) restored — no re-login" "$P/.credentials.json"

# ── (5) kit files refreshed cleanly (no cruft, marked, registered) ────────────
assert_file "kit hook re-placed after rebuild" "$P/hooks/leak-guard.sh"
assert_lit  "kit hook carries managed marker"  "aka-claude-tools:managed-hook" "$P/hooks/leak-guard.sh"
assert_ok   "kit deny re-merged on rebuild" \
  bash -c "jq -e '((.permissions.deny // []) | length) > 0' '$S' >/dev/null"

# ── (6) complexity advisory pointed the user at Path A ────────────────────────
assert_grep "complexity advisory shown"        'complex config' "$SB/log"
assert_grep "advisory flags MCP servers"       'MCP servers'     "$SB/log"
assert_grep "advisory flags @-imports"         '@-imports'       "$SB/log"
assert_grep "advisory points at Path A"        'agent-install.md' "$SB/log"

t_summary
