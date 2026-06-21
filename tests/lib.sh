#!/usr/bin/env bash
# tests/lib.sh — tiny assert + sandbox helpers. Source this at the top of a test.
# No external deps beyond bash + jq + git (the project's own dependencies).
#
# Each test file is run as its own subprocess by tests/run.sh, sources this,
# runs asserts, and ends with `t_summary` (exits non-zero if any assert failed).
# Sandboxes are mktemp dirs, auto-removed on exit — a test NEVER touches a real
# ~/.claude* profile or the real repo working tree.

REPO_ROOT="$(git -C "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" rev-parse --show-toplevel)"
ADDITIONS="$REPO_ROOT/config/additions.json"

_PASS=0 ; _FAIL=0 ; _SANDBOXES=()
trap '_t_cleanup' EXIT
_t_cleanup() { local d; for d in "${_SANDBOXES[@]:-}"; do [ -n "${d:-}" ] && rm -rf "$d"; done; }

sandbox() { local d; d="$(mktemp -d)"; _SANDBOXES+=("$d"); printf '%s' "$d"; }

pass() { _PASS=$((_PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { _FAIL=$((_FAIL+1)); printf '  \033[31m✗ %s\033[0m\n' "$1"; [ -n "${2:-}" ] && printf '      └ %s\n' "$2" >&2; }

# assert_ok   "desc" cmd...   → pass if cmd exits 0
assert_ok()   { local d="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d" "expected exit 0 from: $*"; fi; }
# assert_fail "desc" cmd...   → pass if cmd exits NON-zero (guard rejections)
assert_fail() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then fail "$d" "expected non-zero from: $*"; else pass "$d"; fi; }
# assert_file "desc" path     → pass if path exists
assert_file() { [ -e "$2" ] && pass "$1" || fail "$1" "missing: $2"; }
# assert_grep "desc" pattern file
assert_grep() { grep -qE "$2" "$3" 2>/dev/null && pass "$1" || fail "$1" "pattern '$2' not in $3"; }
# assert_ngrep "desc" pattern file → pattern must be ABSENT
assert_ngrep(){ grep -qE "$2" "$3" 2>/dev/null && fail "$1" "pattern '$2' unexpectedly in $3" || pass "$1"; }
# assert_eq "desc" expected actual
assert_eq()   { [ "$2" = "$3" ] && pass "$1" || fail "$1" "expected '$2', got '$3'"; }

t_summary() {
  printf '  \033[1m%d passed, %d failed\033[0m\n' "$_PASS" "$_FAIL"
  [ "$_FAIL" -eq 0 ]
}
