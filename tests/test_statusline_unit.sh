#!/usr/bin/env bash
# Wrapper so the test_*.sh glob in run.sh picks up the in-process TypeScript unit tests
# for config/hooks/statusline.ts. The real assertions live in statusline.test.ts (run
# under bun, which the suite already preflights as a hard dep). Sandbox HOME/TMPDIR so
# importing the hook — which derives a cache dir at module load — never touches a real
# profile or the operator's shared /tmp.
SB="$(mktemp -d "${TMPDIR:-/tmp}/aka-sl-unit.XXXXXX")"
trap 'rm -rf "$SB"' EXIT
export HOME="$SB" TMPDIR="$SB"
unset CLAUDE_CONFIG_DIR XDG_RUNTIME_DIR
exec bun "$(dirname "${BASH_SOURCE[0]}")/statusline.test.ts"
