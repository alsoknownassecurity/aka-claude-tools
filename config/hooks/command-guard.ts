#!/usr/bin/env bun
// aka-claude-tools:managed-hook — installer-owned; auto-removed on upgrade if renamed/retired. Safe to delete.
/**
 * command-guard.ts — PreToolUse hook for the Bash tool. The SOLE Bash egress guard
 * (bun is a hard dependency of this addition; see install.sh). leak-guard.sh is now
 * WEB-only — all Bash egress checking lives here. It blocks:
 *   - DENY: piping output into a shell (curl … | bash) — structural.
 *   - DENY: writing to a shell STARTUP file (~/.zshrc, ~/.bashrc, …) via a Bash
 *     redirection or write-capable command — a persistence vector the secure-settings
 *     Edit/Write deny can't reach through a Bash redirection. Legit alias writes go
 *     through `./install.sh --alias`, whose command string doesn't match this check.
 * On an OUTBOUND command (one naming curl/wget/nc/ncat/socat/fetch — the ~2% fast
 * gate; ~98% of Bash calls pay ~0 ms), it additionally runs three egress tiers,
 * mirroring leak-guard's old Bash branch so no coverage is lost in the consolidation:
 *   - DENY Tier 1: a detected secret (trufflehog, run local / --no-verification so the
 *     candidate never leaves the box). Degrades to the regex tiers if trufflehog absent.
 *   - DENY Tier 2: a match against your opt-in org markers (CT_EGRESS_PATTERNS). The
 *     pattern is read from the install-COMPILED sidecar lib/org-egress.json — this hook
 *     NEVER sources the user's shell config (a bun process can't safely evaluate
 *     arbitrary shell). install.sh compiles + validates the pattern; here we only
 *     consume validated JSON.
 *   - DENY Tier 3: a shared credential key-SHAPE (from lib/secret-patterns.json — one
 *     source of truth, also read by leak-guard for web egress).
 *   - ALERT (allow + log): other egress vectors (nc/socat/sendmail, env dumps,
 *     inline interpreter execution).
 *
 * Protocol: deny → exit 2 (Claude Code blocks); alert/allow → exit 0.
 *
 * FAIL STATES:
 *   - Shared patterns file missing/corrupt → FAIL CLOSED on outbound commands (block),
 *     since we cannot run the credential scan we're here to run.
 *   - Org sidecar missing / unparseable / malformed → org tier INACTIVE (it is opt-in),
 *     never a crash: this is the sole Bash guard, so a bad sidecar parse must not take
 *     down the pipe-to-shell + trufflehog tiers with it.
 *   - Unparseable stdin → fail open, but LOUDLY (stderr).
 * Requires: bun.
 */
import { readFileSync } from 'fs';
import { spawnSync } from 'child_process';
import { createHash } from 'crypto';

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

// Org-marker tier (opt-in). Reads the install-COMPILED sidecar — never sources the
// user's shell config. FAIL-SOFT on every error (missing / unparseable / malformed /
// bad-regex sidecar → org tier inactive), NEVER throws: this is the sole Bash guard,
// so a bad parse must not crash pipe-to-shell + trufflehog. `stale` is computed
// independently of whether a pattern is set, so a user who ADDS CT_EGRESS_PATTERNS
// after install (sidecar pattern still empty) still gets the "re-run install" nudge.
interface OrgTier { pattern: RegExp | null; stale: boolean }
function loadOrgTier(): OrgTier {
  try {
    const sc = JSON.parse(readFileSync(new URL('./lib/org-egress.json', import.meta.url), 'utf-8')) as
      { pattern?: string; sourceHash?: string };
    let stale = false;
    if (sc.sourceHash) {
      try {
        // Hash the RAW config FILE BYTES — the same byte domain install.sh hashes
        // (NOT the shell-expanded value), so quoting-identical edits don't false-drift.
        const cfg = readFileSync(new URL('../aka-claude-tools.config', import.meta.url));
        stale = createHash('sha256').update(cfg).digest('hex') !== sc.sourceHash;
      } catch { /* config gone/unreadable → can't compare; treat as not-stale */ }
    }
    let pattern: RegExp | null = null;
    if (sc.pattern) { try { pattern = new RegExp(sc.pattern); } catch { pattern = null; } }
    return { pattern, stale };
  } catch {
    return { pattern: null, stale: false };
  }
}

// trufflehog Tier-1 (local, detection-only). Mirrors leak-guard exactly, including
// the missing-binary degradation: warn to stderr + fall through to the regex tiers.
function trufflehogDetects(command: string): boolean {
  const r = spawnSync('trufflehog', ['stdin', '--json', '--no-update', '--no-verification'],
    { input: command, encoding: 'utf-8' });
  if (r.error) {
    console.error('[aka-claude-tools SECURITY] ⚠️ command-guard: trufflehog not installed — secret detection degraded to regex tiers (org markers + shared key shapes).');
    return false;
  }
  return (r.stdout || '').includes('"DetectorName"');
}

function main(): void {
  let input: HookInput;
  try {
    const raw = readFileSync('/dev/stdin', 'utf-8');
    if (!raw.trim()) process.exit(0);
    input = JSON.parse(raw);
  } catch {
    // Fail open, but loudly — this is the sole Bash guard; surface the miss.
    console.error('[aka-claude-tools SECURITY] ⚠️ command-guard: could not parse hook input — allowed. If this recurs, the hook may be misconfigured.');
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

  // Startup-file write — structural persistence-vector check. Runs even in degraded mode.
  if (STARTUP_WRITE.test(command)) {
    console.error('[aka-claude-tools SECURITY] 🚨 BLOCKED (command-guard): writing to a shell startup file (~/.zshrc, ~/.bashrc, …) is a persistence vector. Your dotfiles are Edit/Write-denied; a Bash redirection bypasses that. If intentional, run it in your own shell (e.g. a `! <cmd>` prompt); for a profile alias use `./install.sh --alias`.');
    process.exit(2);
  }

  const patterns = loadPatterns();
  if (!patterns) {
    // FAIL CLOSED on outbound: we can't run the credential scan we exist for.
    if (FALLBACK_OUTBOUND.test(command)) {
      console.error('[aka-claude-tools SECURITY] 🚨 BLOCKED (command-guard): secret-patterns.json is missing or corrupt, so the egress scan can\'t run — blocking this outbound command as a precaution. Restore config/hooks/lib/secret-patterns.json or reinstall.');
      process.exit(2);
    }
    // Non-outbound: nothing to scan for; fall through to structural alerts.
  } else if (patterns.outbound.test(command)) {
    // ── Outbound subset only — mirror leak-guard's old Bash tier order ──
    // Tier 1: high-fidelity secret detection (local-only).
    if (trufflehogDetects(command)) {
      console.error('[aka-claude-tools SECURITY] 🚨 BLOCKED (command-guard): outbound command contains a detected secret (trufflehog). Reference it via an environment variable instead of pasting the literal value.');
      process.exit(2);
    }
    // Tier 2: opt-in org markers (from the install-compiled sidecar).
    const org = loadOrgTier();
    if (org.stale) {
      console.error('[aka-claude-tools SECURITY] ⚠️ command-guard: aka-claude-tools.config changed since install — any CT_EGRESS_PATTERNS edit is NOT active yet. Re-run ./install.sh to recompile the org-marker tier.');
    }
    if (org.pattern && org.pattern.test(command)) {
      console.error('[aka-claude-tools SECURITY] 🚨 BLOCKED (command-guard): outbound command matches an internal identifier from aka-claude-tools.config (hostname, IP, path, or username). Describe it generically instead.');
      process.exit(2);
    }
    // Tier 3: shared credential key shapes (a credential VALUE paired with an outbound tool).
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

// Top-level guard: a deliberate decision exits inside main() (process.exit 0/2);
// only an UNEXPECTED throw reaches here. Degrade the documented way — loud on stderr,
// allow (exit 0) — rather than into bun's undefined non-zero exit, since this is the
// sole Bash guard and a bare crash has no defined open/closed semantics in the harness.
try {
  main();
} catch (e) {
  console.error('[aka-claude-tools SECURITY] ⚠️ command-guard: unexpected error — allowed (surfaced, not silent). ' + String(e));
  process.exit(0);
}
