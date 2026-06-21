#!/usr/bin/env bash
# leak-lib.sh — shared trace/secret patterns for the flow tools. Source it to get
# $LEAK_RE (strict, for scanning code/skill files) plus the component vars
# $LEAK_SECRETS / $LEAK_INFRA / $LEAK_EXTRA for finer-grained use.
#
# The committed patterns are GENERIC and safe to publish — they name NO specific
# person, host, or namespace. Operator-specific identifiers (your name, your
# tailnet name, private namespaces) deliberately stay OUT of the repo so this
# file itself can be public: supply them at runtime via
#   AKA_LEAK_EXTRA='regex|regex'           (env), or
#   tools/leak-patterns.local              (gitignored; one regex per line,
#                                            '#' comments and blank lines ignored).

_leak_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Secret shapes — never legitimate in a public repo, anywhere.
LEAK_SECRETS='-----BEGIN [A-Z ]*PRIVATE KEY-----|sk-ant-[A-Za-z0-9_-]{16,}|gh[posru]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}'

# Generic infra traces — real leaks in CODE/skill files, but they also appear in
# INTENTIONAL doc examples (e.g. config.example), so audit-history.sh treats
# these as warnings rather than hard failures.
LEAK_INFRA='/Users/[a-z]|/home/[a-z]|[a-z0-9-]+\.ts\.net|\b10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\b|\b192\.168\.[0-9]{1,3}\.[0-9]{1,3}\b'

# Operator-specific identifiers — from env + the gitignored local file.
# (Written defensively: this file is sourced into scripts with set -euo pipefail,
# so every line must end with exit status 0 — no bare `[ ] && …` short-circuits,
# and the grep|paste is guarded with `|| true` against pipefail.)
LEAK_EXTRA="${AKA_LEAK_EXTRA:-}"
if [ -f "$_leak_dir/leak-patterns.local" ]; then
  _f="$(grep -vE '^[[:space:]]*(#|$)' "$_leak_dir/leak-patterns.local" | paste -sd'|' - || true)"
  if [ -n "$_f" ]; then LEAK_EXTRA="${LEAK_EXTRA:+$LEAK_EXTRA|}$_f"; fi
fi

# Strict combined pattern: what promote.sh / graduate.sh scan code+skill files for.
LEAK_RE="$LEAK_SECRETS|$LEAK_INFRA"
if [ -n "$LEAK_EXTRA" ]; then LEAK_RE="$LEAK_RE|$LEAK_EXTRA"; fi
