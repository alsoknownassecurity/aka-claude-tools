#!/usr/bin/env bash
# Hook self-clean via managed marker — every shipped hook carries an
# "aka-claude-tools:managed-hook" marker. On a re-run, a MARKED hook the kit no
# longer ships (renamed/retired) is removed and its settings registration pruned;
# an UNMARKED hook (the user's own) is never touched, and a marked hook the kit
# still ships is kept.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_hook_selfclean:"

SB="$(sandbox)"; touch "$SB/.bashrc"; P="$SB/.claude-aka"
run() { CT_ADDITIONS="secure-settings leak-guard" SHELL=/bin/bash HOME="$SB" \
        bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$SB/log" 2>&1; }

run   # initial install — leak-guard ships a marked hook + writes settings.json

# Plant (a) a MARKED stale kit hook the kit no longer ships, and (b) the user's
# OWN unmarked hook — and register both in settings.json.
printf '#!/usr/bin/env bash\n# aka-claude-tools:managed-hook\necho old\n' > "$P/hooks/old-guard.sh"
printf '#!/usr/bin/env bash\necho mine\n'                                 > "$P/hooks/my-hook.sh"
jq --arg o "$P/hooks/old-guard.sh" --arg m "$P/hooks/my-hook.sh" \
   '.hooks.PreToolUse += [{matcher:"Bash",hooks:[{type:"command",command:$o}]},
                          {matcher:"Bash",hooks:[{type:"command",command:$m}]}]' \
   "$P/settings.json" > "$P/s.tmp" && mv "$P/s.tmp" "$P/settings.json"

run   # re-run triggers the marker self-clean
assert_eq "re-run exits 0" "0" "$?"

# The marked, no-longer-shipped hook is gone (file + registration).
[ -e "$P/hooks/old-guard.sh" ] && fail "marked stale hook file removed" "still present" \
                               || pass "marked stale hook file removed"
assert_ok "marked stale hook registration pruned" \
  bash -c "jq -e --arg o '$P/hooks/old-guard.sh' '[.hooks.PreToolUse[]?.hooks[].command] | index(\$o) == null' '$P/settings.json' >/dev/null"

# The user's own (unmarked) hook is untouched — file and registration both stay.
assert_file "unmarked user hook file kept" "$P/hooks/my-hook.sh"
assert_ok "unmarked user hook registration kept" \
  bash -c "jq -e --arg m '$P/hooks/my-hook.sh' '[.hooks.PreToolUse[]?.hooks[].command] | index(\$m) != null' '$P/settings.json' >/dev/null"

# A marked hook the kit STILL ships is kept.
assert_file "currently-shipped marked hook kept" "$P/hooks/leak-guard.ts"
assert_lit "self-clean reported the removal" "managed-marker" "$SB/log"

t_summary
