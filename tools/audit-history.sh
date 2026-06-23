#!/usr/bin/env bash
# audit-history.sh — PRE-SEED GATE. Scans an ENTIRE git history (every blob at
# every commit, plus every commit message) for secrets and operator-specific
# identifiers before that history is published. Because a public repo exposes
# every historical blob via `git show`, the current tree being clean is not
# enough — this checks all of it.
#
# FAILS (exit 1) on: secret shapes + operator-specific identifiers ($LEAK_EXTRA,
#   i.e. your tools/leak-patterns.local) whose VALUE is not allowlisted. These must
#   never be public.
# WARNS (exit 0) on: generic infra patterns ($LEAK_INFRA) — they also appear in
#   intentional doc examples (config.example), so you eyeball them.
#
# Allowlist: tests/audit-allow.txt pins the exact known-FAKE shaped strings that
#   legitimately live in the repo (the egress-guard test corpus). The gate diffs
#   the shaped TOKENS it finds against that list — a shaped value NOT listed FAILs
#   (real leak, or a new un-vetted fixture); a listed one is suppressed and counted.
#
# Usage: tools/audit-history.sh [--repo DIR] [--ref REF]   (default ref: main)
# Tip:   populate tools/leak-patterns.local with your real identifiers first.
set -uo pipefail
_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$_SELF_DIR/leak-lib.sh"

REPO="$(git -C "$_SELF_DIR" rev-parse --show-toplevel 2>/dev/null || echo .)"
REF="main"
while [ $# -gt 0 ]; do case "$1" in
  --repo) REPO="$2"; shift 2;;
  --ref)  REF="$2";  shift 2;;
  -h|--help) sed -n '2,16p' "$0"; exit 0;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done

cd "$REPO" || { echo "no such repo: $REPO" >&2; exit 2; }
echo "auditing $REF in $REPO ($(git rev-list --count "$REF") commits)"

# FAIL set = secrets + operator-specific. WARN set = generic infra.
FAIL_RE="$LEAK_SECRETS"
[ -n "$LEAK_EXTRA" ] && FAIL_RE="$FAIL_RE|$LEAK_EXTRA"
[ -z "$LEAK_EXTRA" ] && echo "note: no operator identifiers loaded (set AKA_LEAK_EXTRA or tools/leak-patterns.local) — checking secrets only for FAIL"

# Allowlist of exact, known-FAKE secret-shaped strings (the egress-guard test
# corpus). VALUE-pinned, not path-scoped, and applied to extracted TOKENS rather
# than whole lines — so it covers commit messages, survives corpus renames, and a
# REAL secret sharing a line with a fake is still caught. Absent file = empty list.
ALLOW_FILE="$REPO/tests/audit-allow.txt"
allow_list=""
[ -f "$ALLOW_FILE" ] && allow_list="$(grep -vE '^[[:space:]]*(#|$)' "$ALLOW_FILE" 2>/dev/null | sort -u || true)"

# count nonempty lines of a newline list (portable; avoids grep -c's no-match exit)
nlines() { [ -z "$1" ] && { echo 0; return; }; printf '%s\n' "$1" | grep -c '[^[:space:]]' 2>/dev/null || true; }

scan_hist() {  # $1 = regex → distinct "file: line" context hits across all history
  local re="$1"
  for c in $(git rev-list "$REF"); do
    git grep -InE -e "$re" "$c" -- . 2>/dev/null
  done | sed -E 's/^[0-9a-f]{40}:[0-9a-f]*://' | sort -u
}
# extract one matched secret TOKEN per line from stdin (so two values on one line
# are two tokens, and an allowlisted fake can't shield a real secret beside it).
extract() { grep -oE -e "$FAIL_RE" 2>/dev/null || true; }

blob_hits="$(scan_hist "$FAIL_RE")"
# Scan commit author/committer IDENTITY (%an/%ae/%cn/%ce) alongside the message
# (%B): a leaked name/email in the identity headers is a real published surface
# the message-only scan misses (e.g. a commit re-introduced under a real address).
msg_hits="$(git log --format='%H%n%an %ae%n%cn %ce%n%B' "$REF" | grep -InE -e "$FAIL_RE" 2>/dev/null || true)"
# Tree entry PATHNAMES are published in tree objects; a leak in a FILENAME (e.g.
# notes-for-<name>.md, /Users/<name>/…) matches neither the blob-content nor the
# message/identity scan, so scan the paths too.
path_hits="$(for c in $(git rev-list "$REF"); do git ls-tree -r --name-only "$c"; done | sort -u | grep -InE -e "$FAIL_RE" 2>/dev/null || true)"
# NOTE (documented limitation): this does not scan raw commit-object headers
# (gpgsig/mergetag/encoding) or nested tag-of-tag objects — published-but-rare
# surfaces, absent in this repo (no signed-tag merges, no tag-of-tags).
warn_hits="$(scan_hist "$LEAK_INFRA")"

# Distinct shaped values found anywhere (blobs + identity/messages + paths), then
# set-diff vs the allowlist. comm needs sorted, newline-delimited inputs.
found="$(printf '%s\n%s\n%s\n' "$blob_hits" "$msg_hits" "$path_hits" | extract | sort -u | grep -v '^$' || true)"
unexpected="$(comm -23 <(printf '%s\n' "$found" | grep -v '^$') <(printf '%s\n' "$allow_list" | grep -v '^$') || true)"
suppressed="$(comm -12 <(printf '%s\n' "$found" | grep -v '^$') <(printf '%s\n' "$allow_list" | grep -v '^$') || true)"
missing="$(comm -13 <(printf '%s\n' "$found" | grep -v '^$') <(printf '%s\n' "$allow_list" | grep -v '^$') || true)"

echo
n_fail="$(nlines "$unexpected")"
if [ -n "$unexpected" ]; then
  echo "✗ FAIL — shaped secret/identifier value(s) NOT in the test-fixture allowlist:"
  printf '%s\n' "$unexpected" | sed 's/^/    /'
  echo "  appearing at:"
  { printf '%s\n' "$blob_hits"; printf '%s\n' "$msg_hits"; printf '%s\n' "$path_hits"; } \
    | grep -F -f <(printf '%s\n' "$unexpected") 2>/dev/null | sort -u | sed 's/^/    /' || true
  echo
fi
if [ -n "$suppressed" ]; then
  echo "• allowlisted test-fixture value(s) found & suppressed ($(nlines "$suppressed")):"
  printf '%s\n' "$suppressed" | sed 's/^/    /'; echo
fi
if [ -n "$missing" ]; then
  echo "⚠ WARN — allowlist entries not present in history (stale fixture? prune tests/audit-allow.txt):"
  printf '%s\n' "$missing" | sed 's/^/    /'; echo
fi
if [ -n "$warn_hits" ]; then
  echo "⚠ WARN — generic infra patterns (confirm these are intentional doc examples):"; echo "$warn_hits"; echo
fi

if [ "$n_fail" -eq 0 ]; then
  echo "✓ no un-allowlisted secrets/identifiers in history — safe to seed (review any warnings above)"
  exit 0
else
  echo "✗ $n_fail un-allowlisted blocking value(s) — scrub before seeding:  git filter-repo --replace-text <patterns>"
  exit 1
fi
