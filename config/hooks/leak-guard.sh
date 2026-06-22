#!/usr/bin/env bash
# aka-claude-tools:managed-hook — installer-owned; auto-removed on upgrade if renamed/retired. Safe to delete.
# leak-guard.sh — PreToolUse hook for WebSearch / WebFetch (WEB egress only).
#
# The WEB egress guard. Pure bash + jq (NO bun) — so the web surface stays guarded
# even if bun is broken (a runtime-diversity hedge), and a web-only install needs no
# bun at all. Bash egress is guarded SEPARATELY by command-guard.ts (the sole Bash
# guard, bun) — this hook no longer touches Bash, so there is exactly one PreToolUse
# process per tool surface. It blocks a web query/url/prompt whose CONTENT carries a
# secret, via:
#   - trufflehog (local / --no-verification — the candidate never leaves the box);
#   - your opt-in org markers (CT_EGRESS_PATTERNS), read from the install-COMPILED
#     sidecar lib/org-egress.json — NOT sourced from the shell config. install.sh
#     compiles + validates the pattern once; both guards consume the same sidecar, so
#     they can't drift and no hook ever evaluates arbitrary shell.
#   - shared credential key-shapes from lib/secret-patterns.json (one source of
#     truth, also read by command-guard for Bash egress).
#
# Reads the Claude Code tool-call JSON from stdin. Exit 2 = block, 0 = allow.
#
# FAIL-CLOSED on things we own: if the shared patterns file is missing/corrupt, the
# guard blocks the web query loudly rather than silently allowing. A bad org config
# is a loud warning, never a silent skip. (jq is a hard install dependency; if it has
# been removed we can't parse the call at all, so we warn loudly and allow — the one
# unavoidable fail-open, and it is surfaced.)
set -euo pipefail

_HOOK_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
_PATTERNS="$_HOOK_DIR/lib/secret-patterns.json"
_ORG_SIDECAR="$_HOOK_DIR/lib/org-egress.json"
_CONFIG="$_HOOK_DIR/../aka-claude-tools.config"

# Portable sha256 of a file → bare lowercase hex (BSD + GNU): sha256sum, else
# shasum -a 256 (ships on macOS), else openssl. Empty if none available. Matches the
# byte domain install.sh hashed into the sidecar's sourceHash.
_sha256_file() {
  if   command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum    >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v openssl   >/dev/null 2>&1; then openssl dgst -sha256 "$1" | awk '{print $NF}'
  else return 1; fi
}

command -v jq >/dev/null 2>&1 || { echo "warn (leak-guard): jq not found (it is a required dependency) — egress scan SKIPPED this call. Reinstall jq." >&2; exit 0; }

input="$(cat)"
tool="$(jq -r '.tool_name // empty' <<<"$input" 2>/dev/null || true)"

# Web tools only — Bash (and everything else) is not this hook's surface.
case "$tool" in
    WebSearch|WebFetch) ;;
    *) exit 0 ;;
esac
query="$(jq -r '[.tool_input.query, .tool_input.url, .tool_input.prompt] | map(select(. != null)) | join(" ")' <<<"$input" 2>/dev/null || true)"
[ -z "$query" ] && exit 0

# ── Load the shared credential definitions (single source of truth) ──
CRED=""
[ -f "$_PATTERNS" ] && CRED="$(jq -r '[.credentialPatterns[].pattern] | join("|")' "$_PATTERNS" 2>/dev/null || true)"
if [ -z "$CRED" ]; then
    # FAIL CLOSED: patterns unloadable — block the web query, loudly.
    echo "egress blocked (leak-guard): secret-patterns.json is missing or unreadable, so the egress scan can't run — blocking this query as a precaution. Restore config/hooks/lib/secret-patterns.json or reinstall." >&2
    exit 2
fi

# ── Tier 1: high-fidelity secret detection (generic, local-only) ──
# --no-verification is load-bearing: without it trufflehog phones the candidate
# secret to the provider to "verify" — i.e. the secret leaves from the very hook
# meant to stop that. Detection stays local.
if command -v trufflehog >/dev/null 2>&1; then
    if printf '%s' "$query" | trufflehog stdin --json --no-update --no-verification 2>/dev/null | grep -q '"DetectorName"'; then
        echo "egress blocked (leak-guard): query contains a detected secret (trufflehog). Reference it via an environment variable instead of pasting the literal value." >&2
        exit 2
    fi
else
    echo "warn (leak-guard): trufflehog not installed — secret detection degraded to regex tiers (org markers + shared key shapes)." >&2
fi

# ── Stale-config advisory (warns, NEVER blocks): if aka-claude-tools.config changed
# since install but the sidecar wasn't recompiled, the org markers below are STALE.
# Mirrors command-guard's sourceHash check, but bun-free (this is the bun-less floor):
# re-hash the raw config bytes with a portable sha256 and compare to the stored hash. ──
if [ -f "$_ORG_SIDECAR" ] && [ -f "$_CONFIG" ]; then
    _wanthash="$(jq -r '.sourceHash // empty' "$_ORG_SIDECAR" 2>/dev/null || true)"
    if [ -n "$_wanthash" ]; then
        _livehash="$(_sha256_file "$_CONFIG" 2>/dev/null || true)"
        if [ -n "$_livehash" ] && [ "$_livehash" != "$_wanthash" ]; then
            echo "warn (leak-guard): aka-claude-tools.config changed since install but its org-egress patterns were not recompiled — the org-marker tier is using STALE patterns. Re-run ./install.sh to recompile. (Web egress is still scanned with the last-compiled patterns.)" >&2
        fi
    fi
fi

# ── Tier 2: opt-in org markers — read the install-COMPILED sidecar (never source
# the shell config; command-guard reads the same sidecar — one source of truth). ──
ORGPAT=""
[ -f "$_ORG_SIDECAR" ] && ORGPAT="$(jq -r '.pattern // empty' "$_ORG_SIDECAR" 2>/dev/null || true)"
if [ -n "$ORGPAT" ]; then
    # `--` guards a pattern that legitimately starts with '-' from being parsed as
    # grep options (BSD + GNU). The pattern was validated as a valid ERE at install.
    _m=0; printf '%s' "$query" | grep -qE -- "$ORGPAT" 2>/dev/null || _m=$?
    if [ "$_m" = 0 ]; then
        echo "egress blocked (leak-guard): query matches an internal identifier from aka-claude-tools.config (hostname, IP, path, or username). Describe it generically instead." >&2
        exit 2
    elif [ "$_m" -gt 1 ]; then
        echo "warn (leak-guard): the compiled org-marker pattern isn't a valid regex — org-marker tier skipped (not silently allowed). Re-run ./install.sh." >&2
    fi
fi

# ── Tier 3: shared generic key shapes (case-sensitive; require a real value) ──
if grep -qE -- "$CRED" <<<"$query"; then
    echo "egress blocked (leak-guard): query contains a token or key value." >&2
    exit 2
fi

exit 0
