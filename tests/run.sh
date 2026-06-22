#!/usr/bin/env bash
# tests/run.sh — run the flow test suite. Each test_*.sh runs as its own
# subprocess (isolated sandboxes); this tallies their exit codes.
#
# Deps: bash, jq, git, bun (the project's own). No network, no real ~/.claude* touched.
# Usage: tests/run.sh            # all tests
#        tests/run.sh manifest   # only tests/test_manifest.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# command-guard is a default-on addition whose runtime is bun, so since bun became a
# hard dependency the default-path install ABORTS without bun — which the ~40 scenario
# tests that run `install.sh --defaults` depend on succeeding. Assert the deps up front
# so a host missing one fails fast with a clear message instead of a confusing cascade
# of mid-suite install aborts. CI installs bun (see .github/workflows/tests.yml).
for _dep in jq git bun; do
  command -v "$_dep" >/dev/null 2>&1 || {
    echo "tests/run.sh: '$_dep' is required to run the suite (a hard dependency of the kit)." >&2
    [ "$_dep" = bun ] && echo "  install bun: https://bun.sh  (command-guard's runtime; install.sh aborts the default install without it)" >&2
    exit 2
  }
done

filter="${1:-}"
fails=0 ; ran=0
for t in test_*.sh; do
  [ -n "$filter" ] && [[ "$t" != *"$filter"* ]] && continue
  ran=$((ran+1))
  bash "$t" || fails=$((fails+1))
  echo
done

[ "$ran" -eq 0 ] && { echo "no tests matched '$filter'"; exit 2; }
if [ "$fails" -eq 0 ]; then
  printf '\033[32m━━ all %d test file(s) passed ━━\033[0m\n' "$ran"
else
  printf '\033[31m━━ %d/%d test file(s) FAILED ━━\033[0m\n' "$fails" "$ran"
fi
exit $(( fails > 0 ? 1 : 0 ))
