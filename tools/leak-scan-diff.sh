#!/usr/bin/env bash
# leak-scan-diff.sh — PRE-MERGE leak gate. Scans ONLY what a branch ADDS vs a base
# (added diff lines + new commit messages/identities + new file paths) for secret
# shapes + operator identifiers, so contamination is caught BEFORE it merges and
# never enters history. Catching it here is what avoids a history-rewrite +
# force-clone across the fleet later (the audit-history full scan is the backstop).
#
# Diff-scoped (not the whole history), so it's fast and unaffected by pre-existing
# history — a new PR fails only if IT introduces a leak.
#
# Usage: tools/leak-scan-diff.sh [BASE]          # default base: origin/main
#        also usable as a pre-commit hook against staged changes (see --staged)
# Identifiers: AKA_LEAK_EXTRA (env) or tools/leak-patterns.local (see leak-lib.sh).
# Exit 0 = clean, 1 = a new secret/identifier was introduced.
set -uo pipefail
_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/leak-lib.sh
source "$_dir/leak-lib.sh"
# Repo = the one we're invoked in (CWD), so CI / a pre-commit hook / a sandbox test
# all scan the right tree. leak-lib + the allowlist come from the script's own dir.
REPO="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
cd "$REPO"

# FAIL set = secret shapes (+ operator identifiers when loaded). Unlike the publish
# gate, this does NOT hard-fail when identifiers are absent (CI on a fork PR can't
# read the secret) — it still catches secret shapes; -e because $LEAK_SECRETS
# starts with '-----BEGIN…' which grep would otherwise read as options.
FAIL_RE="$LEAK_SECRETS"
[ -n "${LEAK_EXTRA:-}" ] && FAIL_RE="$FAIL_RE|$LEAK_EXTRA"

ALLOW="$REPO/tests/audit-allow.txt"
allow=""
[ -f "$ALLOW" ] && allow="$(grep -vE '^[[:space:]]*(#|$)' "$ALLOW" 2>/dev/null | sort -u || true)"

mode="${1:-}"
if [ "$mode" = "--staged" ]; then
  added="$(git diff --cached | grep '^+' | grep -v '^+++' | sed 's/^+//' || true)"
  meta=""                                   # nothing committed yet
  paths="$(git diff --cached --name-only || true)"
  label="staged changes"
else
  BASE="${1:-origin/main}"
  mb="$(git merge-base "$BASE" HEAD 2>/dev/null || echo "$BASE")"
  added="$(git diff "$mb"...HEAD | grep '^+' | grep -v '^+++' | sed 's/^+//' || true)"
  meta="$(git log "$mb"..HEAD --format='%an %ae%n%cn %ce%n%B' 2>/dev/null || true)"
  paths="$(git diff --name-only "$mb"...HEAD || true)"
  label="$BASE...HEAD"
fi

found="$(printf '%s\n%s\n%s\n' "$added" "$meta" "$paths" | grep -oE -e "$FAIL_RE" 2>/dev/null | sort -u | grep -v '^$' || true)"
unexpected="$(comm -23 <(printf '%s\n' "$found" | grep -v '^$') <(printf '%s\n' "$allow" | grep -v '^$') 2>/dev/null || true)"

if [ -n "$unexpected" ]; then
  echo "✗ leak-scan ($label): this change ADDS secret/identifier value(s) not in the allowlist:"
  printf '%s\n' "$unexpected" | sed 's/^/    /'
  echo "  Remove before merge. Never commit real names/hosts/secrets — use synthetic"
  echo "  fixtures (assemble shaped tokens from fragments; see tests/test_tools.sh)."
  exit 1
fi
echo "✓ leak-scan ($label): no new secrets/identifiers introduced"
exit 0
