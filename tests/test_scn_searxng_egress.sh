#!/usr/bin/env bash
# Scenario — leak-guard scans the SearXNG MCP egress surface.
#
# secure-deep-research routes SENSITIVE topics through self-hosted SearXNG (the
# mcp__searxng__* tools) precisely for privacy. leak-guard previously had a hard
# tool-name gate (WebSearch|WebFetch only) and exited 0 on anything else, so a secret
# in a SearXNG query/url egressed UNGUARDED — the matcher and the hook gate must BOTH
# admit SearXNG for the scan to run. This pins the behavioral coverage.
#
# Uses a GitHub-PAT-shaped value (gh[pousr]_… is a shared CRED pattern), so the block
# fires via the always-on regex tier even when trufflehog is absent (CI-deterministic).
#
# Invariants:
#   A. A secret in mcp__searxng__searxng_web_search (.query) is BLOCKED (exit 2).
#   B. A secret in mcp__searxng__web_url_read (.url) is BLOCKED (exit 2).
#   C. A benign SearXNG query is allowed (exit 0) — coverage, not blanket denial.
#   D. WebSearch baseline still blocks (exit 2); a non-web tool is still ignored (exit 0).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_searxng_egress:"

LG="$REPO_ROOT/config/hooks/leak-guard.sh"
SSECRET="ghp_0123456789abcdefghijklmnopqrstuv1234"   # matches the gh[pousr]_ CRED pattern
SB="$(sandbox)"

emit() { printf '%s' "$1" > "$SB/in.json"; bash "$LG" < "$SB/in.json" >/dev/null 2>&1; echo $?; }

# A. SearXNG search with a secret in .query
rc="$(emit "$(jq -nc --arg k "$SSECRET" '{tool_name:"mcp__searxng__searxng_web_search",tool_input:{query:$k}}')")"
assert_eq "secret in SearXNG search (.query) is BLOCKED" "2" "$rc"

# B. SearXNG url-read with a secret in .url
rc="$(emit "$(jq -nc --arg k "$SSECRET" '{tool_name:"mcp__searxng__web_url_read",tool_input:{url:("https://x/"+$k)}}')")"
assert_eq "secret in SearXNG url-read (.url) is BLOCKED" "2" "$rc"

# B2. SearXNG search-suggestions also carries a .query (the other content-bearing tool)
rc="$(emit "$(jq -nc --arg k "$SSECRET" '{tool_name:"mcp__searxng__searxng_search_suggestions",tool_input:{query:$k}}')")"
assert_eq "secret in SearXNG search-suggestions (.query) is BLOCKED" "2" "$rc"

# C. benign SearXNG query is allowed
rc="$(emit "$(jq -nc '{tool_name:"mcp__searxng__searxng_web_search",tool_input:{query:"best pizza near me"}}')")"
assert_eq "benign SearXNG query is ALLOWED" "0" "$rc"

# D. baseline unchanged: WebSearch still blocks; a non-web tool is still out of scope
rc="$(emit "$(jq -nc --arg k "$SSECRET" '{tool_name:"WebSearch",tool_input:{query:$k}}')")"
assert_eq "WebSearch baseline still BLOCKS a secret" "2" "$rc"
rc="$(emit "$(jq -nc --arg k "$SSECRET" '{tool_name:"Read",tool_input:{file_path:("/tmp/"+$k)}}')")"
assert_eq "non-web tool (Read) still IGNORED (exit 0)" "0" "$rc"

# E. The registered MATCHER regex actually fires on the real SearXNG tool names.
#    (The behavioral cases above run leak-guard.sh directly; this bridges to Claude
#    Code's matcher semantics — the matcher is a regex tested against the tool name —
#    so a registration/matcher-string bug can't pass silently.) Source of truth: the
#    matcher in config/additions.json.
MATCHER="$(jq -r '.additions[]|select(.id=="leak-guard")|.matcher' "$ADDITIONS")"
for tn in mcp__searxng__searxng_web_search mcp__searxng__web_url_read \
          mcp__searxng__searxng_search_suggestions mcp__searxng__searxng_instance_info \
          WebSearch WebFetch; do
  printf '%s\n' "$tn" | grep -qE "$MATCHER" && pass "matcher fires on $tn" || fail "matcher fires on $tn" "matcher '$MATCHER' did not match"
done
printf '%s\n' "Bash" | grep -qE "$MATCHER" && fail "matcher must NOT fire on Bash" "over-broad" || pass "matcher does NOT fire on Bash (command-guard's surface)"

t_summary
