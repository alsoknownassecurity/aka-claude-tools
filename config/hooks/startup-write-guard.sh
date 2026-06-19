#!/usr/bin/env bash
# aka-claude-tools:managed-hook — installer-owned; auto-removed on upgrade if renamed/retired. Safe to delete.
# startup-write-guard.sh — PreToolUse hook for the Bash tool.
#
# Blocks Bash commands that WRITE to a shell startup file — append/redirect/tee/
# `sed -i`/cp/mv/ln into ~/.zshrc, ~/.zshenv, ~/.zprofile, ~/.bashrc,
# ~/.bash_profile, ~/.profile (and $ZDOTDIR variants). Closes the gap the
# secure-settings deny leaves open: it denies the Edit/Write TOOLS on dotfiles,
# but a Bash redirection like `echo … >> ~/.zshrc` is a separate, unguarded
# persistence path. READS are fine — only writes are blocked.
#
# GUIDANCE, not a hard boundary: it matches operators+filenames, so heavy
# obfuscation or indirection can evade it. Real restrictions live in
# settings.json permissions.deny; durable persistence review is the shell-audit
# skill. Exit 2 + hint = block. If the write is intentional, run it yourself in
# your own shell (e.g. a `! <cmd>` prompt), not through the agent.
set -euo pipefail

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[ -z "$cmd" ] && exit 0

# startup-file basenames (leading dot), matched anywhere a path can appear
f='\.(zshrc|zshenv|zprofile|bashrc|bash_profile|profile)\b'
# A write is: a redirection (> / >>) whose target is such a file, OR a
# write-capable command (tee/sed -i/cp/mv/install/ln) referencing one. The
# [^|;&]* keeps the match within a single command, not across a pipe/list.
if printf '%s' "$cmd" | grep -qE ">>?[[:space:]]*[^|;&<>]*${f}" \
 || printf '%s' "$cmd" | grep -qE "\b(tee|sed[[:space:]]+-i|cp|mv|install|ln)\b[^|;&]*${f}"; then
  printf 'blocked: writing to a shell startup file is gated (aka-claude-tools startup-write-guard).\n' >&2
  printf 'Startup files are a persistence vector, and your dotfiles are Edit/Write-denied — a Bash redirection bypasses that deny. If this is intentional, run it in your own shell (e.g. a `! <cmd>` prompt), not via the agent.\n' >&2
  exit 2
fi
exit 0
