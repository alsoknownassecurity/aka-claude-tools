#!/usr/bin/env bash
# audit-history.sh — PRE-SEED GATE. Scans an ENTIRE git history (every blob at
# every commit, plus every commit message) for secrets and operator-specific
# identifiers before that history is published. Because a public repo exposes
# every historical blob via `git show`, the current tree being clean is not
# enough — this checks all of it.
#
# FAILS (exit 1) on: secret shapes + operator-specific identifiers ($LEAK_EXTRA,
#   i.e. your tools/leak-patterns.local). These must never be public.
# WARNS (exit 0) on: generic infra patterns ($LEAK_INFRA) — they also appear in
#   intentional doc examples (config.example), so you eyeball them.
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

scan_hist() {  # $1 = regex → distinct "file: line" hits across all history
  local re="$1"
  for c in $(git rev-list "$REF"); do
    git grep -InE -e "$re" "$c" -- . 2>/dev/null
  done | sed -E 's/^[0-9a-f]{40}:[0-9a-f]*://' | sort -u
}

fail_hits="$(scan_hist "$FAIL_RE")"
msg_hits="$(git log --format='%H%n%B' "$REF" | grep -InE -e "$FAIL_RE" || true)"
warn_hits="$(scan_hist "$LEAK_INFRA")"

n_fail=0
if [ -n "$fail_hits" ]; then echo; echo "✗ FAIL — secrets/identifiers in file history:"; echo "$fail_hits"; n_fail=$((n_fail + $(printf '%s\n' "$fail_hits" | grep -c .))); fi
if [ -n "$msg_hits" ];  then echo; echo "✗ FAIL — secrets/identifiers in commit messages:"; echo "$msg_hits"; n_fail=$((n_fail + $(printf '%s\n' "$msg_hits" | grep -c .))); fi
if [ -n "$warn_hits" ]; then echo; echo "⚠ WARN — generic infra patterns (confirm these are intentional doc examples):"; echo "$warn_hits"; fi

echo
if [ "$n_fail" -eq 0 ]; then
  echo "✓ no secrets/identifiers in history — safe to seed (review any warnings above)"
  exit 0
else
  echo "✗ $n_fail blocking hit(s) — scrub before seeding:  git filter-repo --replace-text <patterns>"
  exit 1
fi
