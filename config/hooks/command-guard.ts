#!/usr/bin/env bun
// aka-claude-tools:managed-hook — installer-owned; auto-removed on upgrade if renamed/retired. Safe to delete.
/**
 * command-guard.ts — PreToolUse hook for the Bash tool.
 *
 * The ENHANCED egress layer (present only when bun is installed). It adds, on top
 * of the always-on bash floor (leak-guard.sh):
 *   - DENY: a credential VALUE paired with an actual outbound tool invocation,
 *     using the SHARED source lib/secret-patterns.json (also read by leak-guard.sh
 *     — one source of truth).
 *   - DENY: piping output into a shell (curl … | bash) — also covered by the
 *     floor, so this protection does not vanish if bun is absent.
 *   - DENY: writing to a shell STARTUP file (~/.zshrc, ~/.bashrc, …) via a Bash
 *     redirection or a write-capable command. Closes the gap the secure-settings
 *     Edit/Write deny leaves open (it gates the Edit/Write TOOLS on dotfiles, but a
 *     Bash `echo … >> ~/.zshrc` is a separate, unguarded persistence path). This was
 *     the standalone startup-write-guard addition; it is folded in here so there is
 *     ONE Bash guard. NOTE: the protection is therefore bun-gated — when bun is
 *     absent command-guard does not run and the Bash-redirection path is unguarded (the
 *     Edit/Write TOOL deny in secure-settings still holds). Legitimate alias writes
 *     go through `./install.sh --alias`, the sanctioned rc writer, whose command
 *     string does not match this check.
 *   - ALERT (allow + log): other egress vectors (nc/socat/sendmail, env dumps,
 *     inline interpreter execution).
 *
 * Protocol: deny → exit 2 (Claude Code blocks); alert/allow → exit 0.
 *
 * FAIL STATES:
 *   - Shared patterns file missing/corrupt → FAIL CLOSED on outbound commands
 *     (block), since we cannot run the credential scan we're here to run.
 *   - Unparseable stdin → fail open, but LOUDLY (stderr) — the bash floor still
 *     ran its own checks on this same call, so this is not a silent hole.
 * Requires: bun.
 */
import { readFileSync } from 'fs';

interface HookInput {
  tool_name?: string;
  tool_input?: Record<string, unknown> | string;
}
interface Patterns {
  outboundInvocation: string;
  credentialPatterns: { pattern: string; label: string }[];
}

// Degraded-mode fallback ONLY (patterns unloadable) to find the risky subset to
// fail closed on. NOT the source of truth — that's lib/secret-patterns.json.
const FALLBACK_OUTBOUND = /\b(curl|wget|nc|ncat|socat|fetch)\b/i;
const PIPE_TO_SHELL = /\|\s*(sh|bash|zsh)\b/i;

// Startup-file write (persistence vector) — structural, patterns-independent.
// A shell startup-file basename (leading dot), matched anywhere a path appears.
const STARTUP_FILE = '\\.(zshrc|zshenv|zprofile|bashrc|bash_profile|profile)\\b';
// A WRITE is: a redirection (> / >>) whose target is such a file, OR a
// write-capable command (tee/sed -i/cp/mv/install/ln) referencing one. The
// [^|;&<>]* keeps each match within a single command, not across a pipe/list.
// Reads are unaffected (no redirection / write-command). Mirrors the old
// startup-write-guard.sh regex.
const STARTUP_WRITE = new RegExp(
  `>>?\\s*[^|;&<>]*${STARTUP_FILE}|\\b(tee|sed\\s+-i|cp|mv|install|ln)\\b[^|;&]*${STARTUP_FILE}`,
);

// Structural alerts — command-guard-specific (NOT shared; not secret patterns).
const EGRESS_ALERTS: [RegExp, string][] = [
  [/curl.*(-X POST|--data|\s-d\s)/i, 'HTTP POST via curl'],
  [/wget.*(--post-data|--post-file)/i, 'HTTP POST via wget'],
  [/\bnc\s/i, 'Netcat usage'],
  [/\bncat\s/i, 'Ncat usage'],
  [/\bsocat\s/i, 'Socat usage'],
  [/sendmail\b/i, 'Sendmail usage'],
  [/^(printenv|env)\s*$/i, 'Environment variable dump'],
  [/^set\s*$/i, 'Shell variable dump'],
  [/python3?\s+-c\s/i, 'Python inline execution'],
  [/node\s+-e\s/i, 'Node inline execution'],
  [/ruby\s+-e\s/i, 'Ruby inline execution'],
  [/perl\s+-e\s/i, 'Perl inline execution'],
];

function loadPatterns(): { outbound: RegExp; creds: [RegExp, string][] } | null {
  try {
    const p: Patterns = JSON.parse(readFileSync(new URL('./lib/secret-patterns.json', import.meta.url), 'utf-8'));
    if (!p.outboundInvocation || !Array.isArray(p.credentialPatterns) || p.credentialPatterns.length === 0) return null;
    return {
      outbound: new RegExp(p.outboundInvocation, 'i'),
      creds: p.credentialPatterns.map((c) => [new RegExp(c.pattern), c.label] as [RegExp, string]),
    };
  } catch {
    return null;
  }
}

function main(): void {
  let input: HookInput;
  try {
    const raw = readFileSync('/dev/stdin', 'utf-8');
    if (!raw.trim()) process.exit(0);
    input = JSON.parse(raw);
  } catch {
    // Fail open, but loudly — the bash floor already scanned this same call.
    console.error('[aka-claude-tools SECURITY] ⚠️ command-guard: could not parse hook input — allowed (the bash floor still ran). If this recurs, the hook may be misconfigured.');
    process.exit(0);
  }

  if (input.tool_name !== 'Bash') process.exit(0);

  const command =
    typeof input.tool_input === 'string'
      ? input.tool_input
      : (input.tool_input?.command as string | undefined) ?? '';
  if (!command) process.exit(0);

  // Pipe-to-shell — structural, patterns-independent, runs even in degraded mode.
  if (PIPE_TO_SHELL.test(command)) {
    console.error('[aka-claude-tools SECURITY] 🚨 BLOCKED (command-guard): piping output into a shell interpreter (curl … | bash). Download, inspect, then run.');
    process.exit(2);
  }

  // Startup-file write — structural persistence-vector check (was the standalone
  // startup-write-guard addition). Runs even in degraded mode.
  if (STARTUP_WRITE.test(command)) {
    console.error('[aka-claude-tools SECURITY] 🚨 BLOCKED (command-guard): writing to a shell startup file (~/.zshrc, ~/.bashrc, …) is a persistence vector. Your dotfiles are Edit/Write-denied; a Bash redirection bypasses that. If intentional, run it in your own shell (e.g. a `! <cmd>` prompt); for a profile alias use `./install.sh --alias`.');
    process.exit(2);
  }

  const patterns = loadPatterns();
  if (!patterns) {
    // FAIL CLOSED on outbound: we can't run the credential scan we exist for.
    if (FALLBACK_OUTBOUND.test(command)) {
      console.error('[aka-claude-tools SECURITY] 🚨 BLOCKED (command-guard): secret-patterns.json is missing or corrupt, so the credential scan can\'t run — blocking this outbound command as a precaution. Restore config/hooks/lib/secret-patterns.json or reinstall.');
      process.exit(2);
    }
    // Non-outbound: nothing to scan for; fall through to structural alerts.
  } else if (patterns.outbound.test(command)) {
    // Credential VALUE paired with an actual outbound invocation.
    for (const [pattern, label] of patterns.creds) {
      if (pattern.test(command)) {
        console.error(`[aka-claude-tools SECURITY] 🚨 BLOCKED (command-guard): credential exfiltration — ${label} sent via an outbound tool.`);
        process.exit(2);
      }
    }
  }

  // Other egress vectors — surface but allow.
  for (const [pattern, label] of EGRESS_ALERTS) {
    if (pattern.test(command)) {
      console.error(`[aka-claude-tools SECURITY] ⚠️ egress alert (command-guard): ${label} (allowed).`);
      process.exit(0);
    }
  }

  process.exit(0);
}

main();
