#!/usr/bin/env bash
# aka-claude-tools:managed-hook — installer-owned; auto-removed on upgrade if renamed/retired. Safe to delete.
# leak-guard.sh — PreToolUse hook for WebSearch / WebFetch / Bash.
#
# The ALWAYS-ON egress FLOOR. Pure bash + jq (no heavy runtime dep), so it holds
# even when the bun enhancement (command-guard.ts) is absent or broken. It blocks:
#   - a tool call whose CONTENT carries a secret (web query/url/prompt, or an
#     outbound Bash command), via the SHARED source lib/secret-patterns.json
#     (also read by command-guard.ts — one source of truth), plus trufflehog and
#     your opt-in org markers;
#   - pipe-to-shell structure (… | sh/bash/zsh) — kept HERE in the floor, not
#     only in the bun hook, so it survives bun-absence.
#
# Reads the Claude Code tool-call JSON from stdin. Exit 2 = block, 0 = allow.
#
# FAIL-CLOSED on things we own: if the shared patterns file is missing/corrupt,
# the guard does NOT silently allow — it blocks the scannable subset (outbound
# Bash + web egress) with a loud message. A bad org config is a loud warning,
# never a silent skip. (jq is a hard install dependency; if it has been removed
# we can't parse the call at all, so we warn loudly and allow — that is the one
# unavoidable fail-open, and it is surfaced.)
set -euo pipefail

_HOOK_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
_PATTERNS="$_HOOK_DIR/lib/secret-patterns.json"
# Degraded-mode fallback ONLY (patterns unloadable) to find the risky subset to
# fail closed on. NOT the source of truth — that's lib/secret-patterns.json.
_FALLBACK_OUTBOUND='\b(curl|wget|nc|ncat|socat|fetch)\b'
_PIPE_TO_SHELL='\|[[:space:]]*(sh|bash|zsh)\b'

command -v jq >/dev/null 2>&1 || { echo "warn (leak-guard): jq not found (it is a required dependency) — egress scan SKIPPED this call. Reinstall jq." >&2; exit 0; }

input="$(cat)"
tool="$(jq -r '.tool_name // empty' <<<"$input" 2>/dev/null || true)"

if [ "$tool" = "Bash" ]; then
    query="$(jq -r '.tool_input.command // empty' <<<"$input" 2>/dev/null || true)"
    [ -z "$query" ] && exit 0
    what="outbound command"; is_bash=1
elif [ "$tool" = "WebSearch" ] || [ "$tool" = "WebFetch" ]; then
    query="$(jq -r '[.tool_input.query, .tool_input.url, .tool_input.prompt] | map(select(. != null)) | join(" ")' <<<"$input" 2>/dev/null || true)"
    [ -z "$query" ] && exit 0
    what="query"; is_bash=0
else
    exit 0
fi

# ── pipe-to-shell (structural; runs for any Bash command, gate or no gate) ──
if [ "$is_bash" = 1 ] && grep -qE "$_PIPE_TO_SHELL" <<<"$query"; then
    echo "egress blocked (leak-guard): piping output into a shell (… | sh/bash/zsh). Download, inspect, then run." >&2
    exit 2
fi

# ── Load the shared outbound + credential definitions (single source of truth) ──
OUTBOUND=""; CRED=""
if [ -f "$_PATTERNS" ]; then
    OUTBOUND="$(jq -r '.outboundInvocation // empty' "$_PATTERNS" 2>/dev/null || true)"
    CRED="$(jq -r '[.credentialPatterns[].pattern] | join("|")' "$_PATTERNS" 2>/dev/null || true)"
fi
if [ -z "$OUTBOUND" ] || [ -z "$CRED" ]; then
    # FAIL CLOSED: patterns unloadable. Block the scannable subset, loudly.
    if [ "$is_bash" = 1 ] && ! grep -qiE "$_FALLBACK_OUTBOUND" <<<"$query"; then
        exit 0   # benign non-outbound Bash — nothing this guard would scan anyway
    fi
    echo "egress blocked (leak-guard): secret-patterns.json is missing or unreadable, so the egress scan can't run — blocking this ${what} as a precaution. Restore config/hooks/lib/secret-patterns.json or reinstall." >&2
    exit 2
fi

# ── Bash fast gate: only content-scan commands that actually invoke an outbound tool ──
if [ "$is_bash" = 1 ]; then
    grep -qiE "$OUTBOUND" <<<"$query" || exit 0   # not outbound → no content egress we cover
fi

# ── Tier 1: high-fidelity secret detection (generic, local-only) ──
# --no-verification is load-bearing: without it trufflehog phones the candidate
# secret to the provider to "verify" — i.e. the secret leaves from the very hook
# meant to stop that. Detection stays local.
if command -v trufflehog >/dev/null 2>&1; then
    if printf '%s' "$query" | trufflehog stdin --json --no-update --no-verification 2>/dev/null | grep -q '"DetectorName"'; then
        echo "egress blocked (leak-guard): ${what} contains a detected secret (trufflehog). Reference it via an environment variable instead of pasting the literal value." >&2
        exit 2
    fi
else
    echo "warn (leak-guard): trufflehog not installed — secret detection degraded to regex tiers (org markers + shared key shapes)." >&2
fi

# ── Tier 2: opt-in org markers (only if configured; invalid regex warns, never silently allows) ──
_cfg="${CLAUDETOOLS_CONFIG:-}"
if [ -z "$_cfg" ]; then
    for c in "${CLAUDE_CONFIG_DIR:-}/aka-claude-tools.config" "$HOME/.claude/aka-claude-tools.config"; do
        [ -n "${c%/aka-claude-tools.config}" ] && [ -f "$c" ] && { _cfg="$c"; break; }
    done
fi
CT_EGRESS_PATTERNS=""
if [ -n "$_cfg" ] && [ -f "$_cfg" ]; then
    # shellcheck disable=SC1090
    source "$_cfg" 2>/dev/null || echo "warn (leak-guard): could not load $_cfg — org-marker tier skipped this call." >&2
fi
if [ -n "$CT_EGRESS_PATTERNS" ]; then
    _m=0; printf '%s' "$query" | grep -qE "$CT_EGRESS_PATTERNS" 2>/dev/null || _m=$?
    if [ "$_m" = 0 ]; then
        echo "egress blocked (leak-guard): ${what} matches an internal identifier from aka-claude-tools.config (hostname, IP, path, or username). Describe it generically instead." >&2
        exit 2
    elif [ "$_m" -gt 1 ]; then
        echo "warn (leak-guard): CT_EGRESS_PATTERNS is not a valid regex — org-marker tier skipped (not silently allowed). Fix it in aka-claude-tools.config." >&2
    fi
fi

# ── Tier 3: shared generic key shapes (case-sensitive; require a real value) ──
if grep -qE "$CRED" <<<"$query"; then
    echo "egress blocked (leak-guard): ${what} contains a token or key value." >&2
    exit 2
fi

exit 0
