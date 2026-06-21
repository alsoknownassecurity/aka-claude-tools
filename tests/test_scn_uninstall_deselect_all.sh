#!/usr/bin/env bash
# Uninstall-by-deselect of the WHOLE kit (T24) — re-running with NOTHING selected
# must uninstall every previously-installed addition at once: every kit-owned file
# (hooks, command, skill, statusLine) is deleted and every kit settings entry
# (hook registrations, statusLine, shipped permission/env rules) is pruned. But the
# profile dir and the USER's own data — CLAUDE.md, prompt history, projects/,
# todos/, an unmarked user hook (file + its settings registration), and a settings
# key the user added — must SURVIVE the teardown. And a second deselect-all run is a
# clean no-op (idempotent both ways). Fully sandboxed: fake $HOME, fake bash rc,
# --no-auth-inherit, never touches a real ~/.claude*.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_uninstall_deselect_all:"

SB="$(sandbox)"; touch "$SB/.bashrc"
P="$SB/.claude-aka"

# Recommended subset with NO optional runtime (no bun/rtk/trufflehog), so it's
# CI-stable, yet spans every placeable kind: base settings (perms/env), two hooks
# (leak-guard, harness-pointer), a statusLine (statusline), a command (wrap-up),
# and a skill (shell-audit).
SEL="secure-settings leak-guard harness-pointer statusline wrap-up shell-audit"
run() { CT_ADDITIONS="$1" SHELL=/bin/bash HOME="$SB" \
        bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log" 2>&1; }

# ── (1) full install ─────────────────────────────────────────────────────────
run "$SEL"; rc1=$?
assert_eq   "full install exits 0" "0" "$rc1"
assert_file "leak-guard hook placed"          "$P/hooks/leak-guard.sh"
assert_file "harness-pointer hook placed" "$P/hooks/harness-pointer.sh"
assert_file "statusline hook placed"         "$P/hooks/statusline.sh"
assert_file "wrap-up command placed"         "$P/commands/wrap-up.md"
assert_file "shell-audit skill placed"       "$P/skills/shell-audit"
assert_ok   "leak-guard registered in settings" \
  bash -c "jq -e '[.hooks.PreToolUse[]?.hooks[].command] | any(.[]; endswith(\"/leak-guard.sh\"))' '$P/settings.json' >/dev/null"
assert_ok   "statusLine wired in settings" \
  bash -c "jq -e '(.statusLine.command // \"\") | endswith(\"/statusline.sh\")' '$P/settings.json' >/dev/null"
# secure-settings shipped permission rules — confirm some landed (so we can prove
# they get pruned on deselect-all).
assert_ok   "shipped permission rules present after install" \
  bash -c "jq -e '((.permissions.deny // []) | length) > 0' '$P/settings.json' >/dev/null"

# ── (2) seed the USER's own data on top of the kit ───────────────────────────
echo "# my global memory"          > "$P/CLAUDE.md"
echo '{"event":"hi"}'              > "$P/history.jsonl"
mkdir -p "$P/projects/proj/memory"; echo "a lesson" > "$P/projects/proj/memory/x.md"
mkdir -p "$P/todos";                echo "[]"        > "$P/todos/t.json"

# A user-OWNED hook (unmarked — no managed marker) + its settings registration.
# The kit must never delete it on a deselect-all.
printf '#!/usr/bin/env bash\necho mine\n' > "$P/hooks/my-hook.sh"
# A settings key the user added by hand (a deny rule the kit never shipped, plus a
# bespoke top-level key the merge/prune logic should never touch).
USER_DENY='Read(//Users/me/private/**)'
jq --arg m "$P/hooks/my-hook.sh" --arg d "$USER_DENY" \
   '.hooks.PreToolUse += [{matcher:"Bash",hooks:[{type:"command",command:$m}]}]
    | .permissions.deny = ((.permissions.deny // []) + [$d])
    | .myCustomKey = "keep me"' \
   "$P/settings.json" > "$P/s.tmp" && mv "$P/s.tmp" "$P/settings.json"
assert_ok "seeded settings is valid JSON" jq -e . "$P/settings.json"

# ── (3) DESELECT ALL — the whole-kit uninstall ───────────────────────────────
run ""; rc2=$?
assert_eq "deselect-all run exits 0" "0" "$rc2"

# 3a. Profile dir itself REMAINS (uninstall ≠ delete-the-profile).
assert_file "profile dir still exists after deselect-all" "$P"

# 3b. Every kit-owned FILE removed.
for f in hooks/leak-guard.sh hooks/harness-pointer.sh hooks/statusline.sh \
         commands/wrap-up.md skills/shell-audit; do
  if [ -e "$P/$f" ]; then fail "kit file removed: $f" "still present"
  else pass "kit file removed: $f"; fi
done

# 3c. Every kit SETTINGS entry pruned. Settings stays valid JSON.
assert_ok "settings.json still valid JSON after deselect-all" jq -e . "$P/settings.json"
assert_ok "leak-guard registration pruned" \
  bash -c "jq -e '[.hooks.PreToolUse[]?.hooks[].command] | any(.[]; endswith(\"/leak-guard.sh\")) | not' '$P/settings.json' >/dev/null"
assert_ok "harness-pointer registration pruned" \
  bash -c "jq -e '[.hooks.PreToolUse[]?.hooks[].command] | any(.[]; endswith(\"/harness-pointer.sh\")) | not' '$P/settings.json' >/dev/null"
assert_ok "statusLine pruned from settings" \
  bash -c "jq -e '((.statusLine.command // \"\") | endswith(\"/statusline.sh\")) | not' '$P/settings.json' >/dev/null"
# The permission rules secure-settings shipped are gone, while the user's own deny
# rule survives — proves the prune is kit-scoped, not a blanket wipe.
assert_ok "user-added deny rule SURVIVES the prune" \
  bash -c "jq -e --arg d '$USER_DENY' '((.permissions.deny // []) | index(\$d)) != null' '$P/settings.json' >/dev/null"
assert_ok "user-added top-level settings key SURVIVES" \
  bash -c "jq -e '.myCustomKey == \"keep me\"' '$P/settings.json' >/dev/null"

# 3d. The USER's own (unmarked) hook is untouched — file AND registration both stay.
assert_file "unmarked user hook file kept" "$P/hooks/my-hook.sh"
assert_ok "unmarked user hook registration kept" \
  bash -c "jq -e --arg m '$P/hooks/my-hook.sh' '[.hooks.PreToolUse[]?.hooks[].command] | index(\$m) != null' '$P/settings.json' >/dev/null"

# 3e. The USER's data files all survive.
assert_file "CLAUDE.md kept"            "$P/CLAUDE.md"
assert_grep "CLAUDE.md content intact"  'my global memory' "$P/CLAUDE.md"
assert_file "history.jsonl kept"        "$P/history.jsonl"
assert_file "projects/memory kept"      "$P/projects/proj/memory/x.md"
assert_file "todos kept"                "$P/todos/t.json"

cp "$P/settings.json" "$SB/after_deselect1.json"

# ── (4) IDEMPOTENT: a second deselect-all is a clean no-op ───────────────────
run ""; rc3=$?
assert_eq "second deselect-all run exits 0" "0" "$rc3"
cp "$P/settings.json" "$SB/after_deselect2.json"

if diff <(jq -S . "$SB/after_deselect1.json") <(jq -S . "$SB/after_deselect2.json") >/dev/null 2>&1; then
  pass "settings.json canonical-identical across re-deselect (idempotent)"
else
  fail "settings.json canonical-identical across re-deselect (idempotent)" \
       "second deselect-all changed settings"
fi

# User data and the user hook still intact after the second pass.
assert_file "CLAUDE.md still kept after 2nd deselect"   "$P/CLAUDE.md"
assert_file "history.jsonl still kept after 2nd deselect" "$P/history.jsonl"
assert_file "user hook still kept after 2nd deselect"  "$P/hooks/my-hook.sh"
assert_file "profile dir still exists after 2nd deselect" "$P"

t_summary
