#!/usr/bin/env bash
# Forward flow: install.sh deploys the product into a profile. Fully sandboxed by
# overriding $HOME to a temp dir (install picks $HOME/.claude-aka by default and
# reads config from its own REPO_DIR) — no real ~/.claude* is ever touched.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_install:"

SB="$(sandbox)"
out="$SB/install.log"
HOME="$SB" bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$out" 2>&1
rc=$?
PROFILE="$SB/.claude-aka"

assert_eq   "install.sh exits 0" "0" "$rc"
assert_file "profile dir created" "$PROFILE"
assert_ok   "settings.json is valid JSON" jq -e . "$PROFILE/settings.json"

# Every RECOMMENDED addition's declared artifact must land in the profile, with
# the path remap applied (config/<X> in repo  ->  <X> in profile). Dynamic, so
# the test keeps protecting the flow as additions change.
while IFS= read -r rel; do
  [ -z "$rel" ] && continue
  assert_file "deployed (remapped): $rel" "$PROFILE/$rel"
done < <(jq -r '.additions[] | select(.recommended==true) | .skill, .hook, .command | select(.!=null)' "$ADDITIONS")

# The deployed settings must NOT leak maintainer-only "$comment" keys.
assert_ok   "no \$comment keys in deployed settings" \
  bash -c 'jq -e "[.. | objects | keys[]] | index(\"\$comment\") | not" "'"$PROFILE/settings.json"'" >/dev/null'

# A clean install should report success, not an error.
assert_grep "install reported done" 'Done|ready' "$out"

t_summary
