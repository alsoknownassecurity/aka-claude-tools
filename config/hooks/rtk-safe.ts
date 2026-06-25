#!/usr/bin/env bun
// aka-claude-tools:managed-hook — installer-owned; auto-removed on upgrade if renamed/retired. Safe to delete.
/**
 * rtk-safe.ts — PreToolUse rewrite hook for the Bash tool. Transparently rewrites the
 * command of a Bash invocation to its compact `rtk` equivalent so verbose tool output
 * (git/gh/ls/find/test runners/…) is token-reduced before it reaches the model. It only
 * ever REWRITES the command string (via hookSpecificOutput.updatedInput); it never
 * approves anything — the rewritten command still flows through the normal permission
 * rules, so a mutating/outbound form (rtk curl, rtk git push, …) keeps prompting.
 *
 * Design: a single ordered rule table (RULES). Each rule inspects the leading command and
 * returns the rewritten command body or null ("not mine"); the first non-null wins. Most
 * rules just front the command with `rtk` (optionally gated to a safe subcommand set); a
 * few normalize a form (head -N → rtk read --max-lines N, npm run X → rtk npm X, the test
 * runners → rtk vitest run). Leading `NAME=val` env assignments are split off for matching
 * and re-attached verbatim to the rewrite.
 *
 * Self-skip (exit 0, no rewrite) when:
 *   - the tool is not Bash, or the command is empty;
 *   - `rtk` is not on PATH (the hook is inert until the user installs rtk);
 *   - the command already invokes rtk, contains a heredoc (<<), or spans multiple lines
 *     (the rule set assumes single-line semantics — a multi-line body would mis-rewrite);
 *   - no rule matches.
 *
 * Credential safety: a `cat`/`head` whose LITERAL command text names a credential-bearing
 * path is left UNREWRITTEN, so it stays a reader Claude Code recognizes and the
 * secure-settings Read(...) deny still binds (rewriting to `rtk read` — an unrecognized
 * reader — would slip it past that deny). This is a best-effort guard on the obvious,
 * accidental case (the model typing `cat ~/.ssh/id_rsa`), matching the prior hook's
 * behavior and command-guard's threat model; it scans only the raw string, so it does NOT
 * see a credential path reached via a variable, symlink, or command substitution — those
 * are out of scope here (a determined exfil is command-guard's surface, not a token-saver's).
 * Keep CRED_PATH in sync with settings.base.json's denied read paths.
 *
 * Requires: bun (registered as `<bun> <dir>/rtk-safe.ts`). Unlike the old bash version it
 * cannot degrade-run without bun; the installer makes bun a hard dependency of this addition.
 */
import { readFileSync } from 'fs';

interface HookInput {
  tool_name?: string;
  tool_input?: Record<string, unknown> | string;
}

// Leading `NAME=val ` assignment(s) — split off before matching, re-attached to the rewrite.
const ENV_PREFIX = /^([A-Za-z_]\w*=\S* +)+/;
// Command already routed through rtk (bare `rtk …` or a path `…/rtk …`).
const ALREADY_RTK = /^(\S*\/)?rtk\s/;

// Credential-bearing read targets — a cat/head of one of these must NOT be rewritten (see
// the header note). Mirrors the secure-settings denied read set; functional, not creative.
const CRED_PATH =
  /\.(ssh|gnupg|aws|azure|kube|pypirc|netrc|electrum|ethereum)($|[^\w])|\.npmrc($|[^\w])|\/gcloud\/|\.docker\/config\.json|\.gem\/credentials|\.git-credentials|\/\.config\/gh\/|Library\/Keychains\/|Application Support\/Electrum|\/Electrum\/|\/Exodus\/|Library\/Ethereum\/|\/[Mm]eta[Mm]ask\/|\/[Pp]hantom\/|\/[Ss]olflare\/|(^|[^\w.])\.env($|[^\w])/;

// ── small command helpers ─────────────────────────────────────────────────────
const leadWord = (cmd: string): string => cmd.trimStart().split(/\s+/, 1)[0] ?? '';
const startsWithWord = (cmd: string, word: string): boolean =>
  cmd === word || cmd.startsWith(word + ' ');
// Like startsWithWord but REQUIRES at least one argument — for commands that are a no-op
// bare (cat/find/diff/curl/wget/aws), matching the old hook's `^cmd[[:space:]]+` anchor.
const withArgs = (cmd: string, word: string): boolean => cmd.startsWith(word + ' ');
// front the whole body with `rtk ` (the common case).
const front = (body: string): string => 'rtk ' + body;

// Drop a leading program token plus a set of global option forms to expose the
// subcommand. `valued` options consume a following argument (`-C dir`); `--x=y` and the
// listed long flags are dropped inline. Used by git/docker/kubectl subcommand gating.
function subcommand(
  body: string,
  prog: string,
  opts: { valued?: RegExp; longFlags?: RegExp } = {},
): string {
  let rest = body.slice(prog.length).trimStart();
  for (;;) {
    const tok = rest.split(/\s+/, 1)[0] ?? '';
    if (!tok) break;
    if (opts.valued?.test(tok)) {
      // option + its separate argument
      const after = rest.slice(tok.length).trimStart();
      rest = after.slice((after.split(/\s+/, 1)[0] ?? '').length).trimStart();
      continue;
    }
    if (/^--[a-z][\w-]*=/.test(tok) || opts.longFlags?.test(tok)) {
      rest = rest.slice(tok.length).trimStart();
      continue;
    }
    break;
  }
  return rest.split(/\s+/, 1)[0] ?? '';
}

// ── rule table (ordered; first non-null wins) ─────────────────────────────────
type Rule = (body: string) => string | null;

const GIT_SUBCMDS = new Set([
  'status', 'diff', 'log', 'add', 'commit', 'push', 'pull', 'branch', 'fetch', 'stash', 'show',
]);
const CARGO_SUBCMDS = new Set(['test', 'build', 'clippy', 'check', 'install', 'fmt']);
const DOCKER_SUBCMDS = new Set(['ps', 'images', 'logs', 'run', 'build', 'exec']);
const DOCKER_COMPOSE_SUBCMDS = new Set(['ps', 'logs', 'build']);
const KUBECTL_SUBCMDS = new Set(['get', 'logs', 'describe', 'apply']);

const RULES: Rule[] = [
  // git — only the common read/write subcommands (strip -C/-c <arg>, --x=y, a few long flags).
  (b) => {
    if (!startsWithWord(leadWord(b), 'git')) return null;
    const sub = subcommand(b, 'git', {
      valued: /^-[Cc]$/,
      longFlags: /^--(no-pager|no-optional-locks|bare|literal-pathspecs)$/,
    });
    return GIT_SUBCMDS.has(sub) ? front(b) : null;
  },
  // gh — the verbose, paginated surfaces.
  (b) => {
    const sub = subcommand(b, 'gh');
    return startsWithWord(leadWord(b), 'gh') && ['pr', 'issue', 'run', 'api', 'release'].includes(sub)
      ? front(b)
      : null;
  },
  // cargo — allow an optional +toolchain before the subcommand.
  (b) => {
    if (!startsWithWord(leadWord(b), 'cargo')) return null;
    let rest = b.slice('cargo'.length).trimStart();
    if (rest.startsWith('+')) rest = rest.slice((rest.split(/\s+/, 1)[0] ?? '').length).trimStart();
    return CARGO_SUBCMDS.has(rest.split(/\s+/, 1)[0] ?? '') ? front(b) : null;
  },

  // file reads — cat/head become `rtk read`; a credential-path target is left alone.
  (b) => {
    if (!withArgs(b, 'cat')) return null;
    if (CRED_PATH.test(b)) return null;
    return 'rtk read ' + b.slice('cat'.length).trimStart();
  },
  (b) => {
    if (!startsWithWord(leadWord(b), 'head')) return null;
    if (CRED_PATH.test(b)) return null;
    // head -N file / head --lines=N file → rtk read file --max-lines N
    const m = b.match(/^head\s+(?:-(\d+)|--lines=(\d+))\s+(.+)$/);
    if (m) {
      const n = m[1] ?? m[2];
      return `rtk read ${m[3]} --max-lines ${n}`;
    }
    return null;
  },
  // rg/grep are deliberately NOT rewritten — see issue #37 for the full benchmark.
  // Short: rtk grep 0.42.4 silently inverts -v (its own -v = verbosity, not grep's invert)
  // and its "N matches in 0 files" path returns empty output for the fleet's most common
  // shape (grep -n). Re-evaluate only after rtk fixes the empty-display bug AND stops
  // shadowing -v; re-run the flag-distribution benchmark before re-enabling.
  (b) => (startsWithWord(leadWord(b), 'ls') ? front(b) : null),
  (b) => (startsWithWord(leadWord(b), 'tree') ? front(b) : null),
  (b) => (withArgs(b, 'find') ? front(b) : null),
  (b) => (withArgs(b, 'diff') ? front(b) : null),

  // JS/TS — normalize the test/type/lint runners onto their rtk forms.
  (b) => {
    const m = b.match(/^(?:pnpm\s+)?(?:npx\s+)?vitest(?:\s+run)?(\s.*|$)/);
    return m ? 'rtk vitest run' + m[1] : null;
  },
  (b) => (startsWithWord(b, 'pnpm test') ? 'rtk vitest run' + b.slice('pnpm test'.length) : null),
  (b) => (startsWithWord(b, 'npm test') ? 'rtk npm test' + b.slice('npm test'.length) : null),
  (b) => {
    const m = b.match(/^npm\s+run\s+(.+)$/);
    return m ? 'rtk npm ' + m[1] : null;
  },
  (b) => {
    const m = b.match(/^(?:npx\s+)?vue-tsc(\s.*|$)/);
    return m ? 'rtk tsc' + m[1] : null;
  },
  (b) => (startsWithWord(b, 'pnpm tsc') ? 'rtk tsc' + b.slice('pnpm tsc'.length) : null),
  (b) => {
    const m = b.match(/^(?:npx\s+)?tsc(\s.*|$)/);
    return m ? 'rtk tsc' + m[1] : null;
  },
  (b) => (startsWithWord(b, 'pnpm lint') ? 'rtk lint' + b.slice('pnpm lint'.length) : null),
  (b) => {
    const m = b.match(/^(?:npx\s+)?eslint(\s.*|$)/);
    return m ? 'rtk lint' + m[1] : null;
  },
  (b) => {
    const m = b.match(/^(?:npx\s+)?prettier(\s.*|$)/);
    return m ? 'rtk prettier' + m[1] : null;
  },
  (b) => {
    const m = b.match(/^(?:npx\s+)?prisma(\s.*|$)/);
    return m ? 'rtk prisma' + m[1] : null;
  },

  // containers — gated subcommand sets (compose handled before the generic docker path).
  (b) => {
    if (!startsWithWord(leadWord(b), 'docker')) return null;
    if (/^docker\s+compose($|\s)/.test(b)) {
      const sub = b.replace(/^docker\s+compose\s*/, '').split(/\s+/, 1)[0] ?? '';
      return DOCKER_COMPOSE_SUBCMDS.has(sub) ? front(b) : null;
    }
    const sub = subcommand(b, 'docker', {
      valued: /^(-H|--context|--config)$/,
    });
    return DOCKER_SUBCMDS.has(sub) ? front(b) : null;
  },
  (b) => {
    if (!startsWithWord(leadWord(b), 'kubectl')) return null;
    const sub = subcommand(b, 'kubectl', {
      valued: /^(--context|--kubeconfig|--namespace|-n)$/,
    });
    return KUBECTL_SUBCMDS.has(sub) ? front(b) : null;
  },

  // network — fronted (still prompts; rtk curl/wget are not auto-approved).
  (b) => (withArgs(b, 'curl') ? front(b) : null),
  (b) => (withArgs(b, 'wget') ? front(b) : null),

  // pnpm package queries.
  (b) => {
    const sub = subcommand(b, 'pnpm');
    return startsWithWord(leadWord(b), 'pnpm') && ['list', 'ls', 'outdated'].includes(sub)
      ? front(b)
      : null;
  },

  // python tooling.
  (b) => (startsWithWord(leadWord(b), 'pytest') ? front(b) : null),
  (b) => (startsWithWord(b, 'python -m pytest') ? 'rtk pytest' + b.slice('python -m pytest'.length) : null),
  (b) => {
    const sub = subcommand(b, 'ruff');
    return startsWithWord(leadWord(b), 'ruff') && ['check', 'format'].includes(sub) ? front(b) : null;
  },
  (b) => {
    const sub = subcommand(b, 'pip');
    return startsWithWord(leadWord(b), 'pip') && ['list', 'outdated', 'install', 'show'].includes(sub)
      ? front(b)
      : null;
  },
  (b) => {
    if (!/^uv\s+pip($|\s)/.test(b)) return null;
    const sub = b.replace(/^uv\s+pip\s*/, '').split(/\s+/, 1)[0] ?? '';
    return ['list', 'outdated', 'install', 'show'].includes(sub) ? 'rtk pip ' + b.replace(/^uv\s+pip\s*/, '') : null;
  },
  (b) => (startsWithWord(leadWord(b), 'mypy') ? front(b) : null),
  (b) => (startsWithWord(b, 'python -m mypy') ? 'rtk mypy' + b.slice('python -m mypy'.length) : null),

  // go tooling.
  (b) => {
    if (!startsWithWord(leadWord(b), 'go')) return null;
    const sub = b.slice('go'.length).trimStart().split(/\s+/, 1)[0] ?? '';
    return ['test', 'build', 'vet'].includes(sub) ? front(b) : null;
  },
  (b) => (startsWithWord(leadWord(b), 'golangci-lint') ? front(b) : null),

  // misc CLIs.
  (b) => (withArgs(b, 'aws') ? front(b) : null),
  (b) => (startsWithWord(leadWord(b), 'psql') ? front(b) : null),
];

/** Compute the rewritten command (incl. env prefix), or null if nothing applies. */
export function rewrite(command: string): string | null {
  if (ALREADY_RTK.test(command) || command.includes('<<') || command.includes('\n')) return null;
  const prefix = command.match(ENV_PREFIX)?.[0] ?? '';
  const body = command.slice(prefix.length);
  for (const rule of RULES) {
    const out = rule(body);
    if (out !== null) return prefix + out;
  }
  return null;
}

function main(): void {
  // Inert until rtk is installed — nothing to rewrite onto.
  if (!Bun.which('rtk')) process.exit(0);

  let input: HookInput;
  try {
    const raw = readFileSync('/dev/stdin', 'utf-8');
    if (!raw.trim()) process.exit(0);
    input = JSON.parse(raw);
  } catch {
    process.exit(0); // a rewrite hook fails open: a parse miss must never block a command.
  }

  if (input.tool_name !== 'Bash') process.exit(0);
  const command =
    typeof input.tool_input === 'string'
      ? input.tool_input
      : (input.tool_input?.command as string | undefined) ?? '';
  if (!command) process.exit(0);

  const rewritten = rewrite(command);
  if (rewritten === null || rewritten === command) process.exit(0);

  // Preserve all original tool_input fields; change only `command`. No permissionDecision:
  // the rewritten command is re-evaluated by the normal allow/deny/ask flow (returning
  // "allow" here would silently grant every rewritten curl/docker/git push).
  const toolInput =
    typeof input.tool_input === 'object' && input.tool_input !== null ? input.tool_input : {};
  const updatedInput = { ...toolInput, command: rewritten };
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: { hookEventName: 'PreToolUse', updatedInput },
    }),
  );
  process.exit(0);
}

// Only run main() when executed directly; importing for tests must not read stdin/exit.
// A rewrite hook must FAIL OPEN: any unexpected throw → no rewrite (the command runs
// as-is under the normal permission rules). It never blocks and never auto-approves, so
// failing open here cannot weaken a security boundary (that is command-guard's job).
if (import.meta.main) {
  try {
    main();
  } catch {
    process.exit(0);
  }
}
