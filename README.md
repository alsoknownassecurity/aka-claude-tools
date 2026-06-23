# aka-claude-tools

**The floor a fresh Claude Code should start from** — clean context, locked
credentials, guarded egress. Installed into its own **isolated profile**, so your
existing setup is never touched. Pick-and-choose, no lock-in.

From [alsoknownassecurity](https://github.com/alsoknownassecurity) · MIT · needs `jq` + `bun`.

---

## Powerful out of the box. Bare out of the box.

Claude Code is a capable coding agent on day one — and it ships with the guardrails of
a blank text editor. `aka-claude-tools` adds **nine optional pieces** — six on by
default, three you opt in — that give it clean context, locked doors, and guarded exits.

Every piece is **independent**: take what you want, ignore the rest, delete any in
seconds. No framework, nothing proprietary, nothing phones home.

## Quick start

```bash
git clone git@github.com:alsoknownassecurity/aka-claude-tools.git
cd aka-claude-tools
```

Nothing has run yet — you've only downloaded it. Then, **two ways in, same destination:**

**Path A — hand it to your AI (recommended).** In an existing, logged-in Claude Code
session, say:

> Read agent-install.md and set up a new hardened profile for me.

It reads the guide, checks what you already have, migrates anything custom, and runs the
installer — no commands to type. Spec: [`agent-install.md`](agent-install.md).

**Path B — run the installer.**

```bash
./install.sh             # interactive
./install.sh --defaults  # take every default + the recommended six
```

It asks where to put the profile (default `~/.claude-aka`), what to name the launcher
(default `aka`), and which additions to enable.

**Launch it** — `aka` opens a Claude Code with its own settings, hooks, and history.
Your normal `claude` is completely untouched.

**Then verify the controls actually fire** — a guardrail you haven't watched fire is one
you're only assuming works:

- Ask it to read `~/.ssh/id_rsa` → it should **refuse**.
- Check the status bar → context + rate-limit gauges should show.
- Try `curl … | bash` → command-guard should **block** it.

## What's inside

Nine additions, grouped by what they do. **●** on by default · **○** opt-in.

**Clean context** — keep the model's working memory for the work.
- **● rtk-safe** — rewrites chatty commands (giant listings, logs) into compact summaries
  *before* they reach the model — **cut ~75% of routed command-output tokens** in a 90-day
  production sample. Inert until you install [`rtk`](https://github.com/rtk-ai/rtk).
- **● statusline** — a status bar showing context fill and rate-limit budget live, so you
  know when to wrap a session.

**Locked doors** — safe defaults a fresh install should already have.
- **● secure-settings** — the agent can't read your SSH keys, cloud credentials, `.env`
  files, or keychains; can't write your shell startup files; telemetry off; untrusted
  plugins don't auto-load.

**Guarded exits** — watch what leaves, and what runs.
- **● leak-guard** — inspects what the agent sends to the web (searches, fetches) and
  blocks anything shaped like a secret. Scanned locally; nothing is uploaded to check it.
- **● command-guard** — watches shell commands: blocks piping a web script straight into
  your shell, edits to your startup files, and credentials being shipped out.

**Verify & hand off** — check the work before it ships.
- **● shell-audit** — on-demand, read-only scan of your shell setup; flags hardcoded
  credentials, sketchy startup hooks, and risky aliases in your dotfiles.
- **○ /wrap-up** — a clean end-of-session routine: summarizes, verifies, and stages a
  commit for you to review — never commits on its own.

**Optional extras** — off until you want them.
- **○ secure-deep-research** — privacy-aware web research that routes through your own
  search instance and gates sensitive topics.
- **○ harness-pointer** — a small nudge pointing the agent at the right CLI for your
  environment. Ships disabled and empty.

| On by default | Opt in |
|---|---|
| secure-settings · leak-guard · command-guard · rtk-safe · statusline · shell-audit | /wrap-up · secure-deep-research · harness-pointer |

The full manifest — what each piece places, its settings — is
[`config/additions.json`](config/additions.json), the single source both install paths read.

## Why a kit, not a framework

This isn't a platform you adopt. It's the **floor** — clean context, locked credentials,
guarded egress — that a coding agent ought to start from.

- **Isolated.** Each profile is its own `CLAUDE_CONFIG_DIR` folder with its own settings,
  hooks, and history, launched by alias. Your real `~/.claude` is never touched unless you
  point at it explicitly.
- **Independent.** Every addition stands alone — break one, the rest are fine. Re-run the
  installer to add, remove, or change what's enabled; deselecting uninstalls cleanly.
- **Reversible.** Don't like it? Delete the profile — your real setup never changed.

## Requirements

`jq` and `bun` (the guards and status line run on bun). Optional:
[`trufflehog`](https://github.com/trufflesecurity/trufflehog) for stronger secret
detection, [`rtk`](https://github.com/rtk-ai/rtk) for the rewrite addition. The installer
checks each and offers to install it (with consent) via your package manager. macOS or Linux.

## Managing a profile

- **Login** — the installer inherits your existing Claude Code login, so the new profile
  doesn't re-onboard. Use `--no-auth-inherit` when the profile is for a *different* account.
- **Upgrade** — `git pull`, then re-run against your profile (e.g. `aka`'s `~/.claude-aka`).
  It layers in place: your own settings are preserved, the kit's own rules reconciled.
  Easiest via Path A.
- **Uninstall** — `./uninstall.sh` discovers your profiles and lets you pick one (or name
  it: `./uninstall.sh ~/.claude-aka`). Removes the profile folder and its alias block;
  your default `~/.claude` is never touched. To drop a single addition instead, re-run the
  installer without it.

## Details

Deeper mechanics live in linked docs rather than here:

- **Full lifecycle** — install, upgrade, migrating a rich existing config, the `--apply` /
  `--alias` engine modes, non-interactive `CT_ADDITIONS` / `CT_CONFIG_DIR`: [`agent-install.md`](agent-install.md).
- **Org-specific config** — block your internal hostnames/IPs/paths from web egress, or
  steer the agent off a banned CLI: [`shared/aka-claude-tools.config.example`](shared/aka-claude-tools.config.example).
- **Shared secret patterns** the guards match: [`config/hooks/lib/secret-patterns.json`](config/hooks/lib/secret-patterns.json).

## Security

The egress guards are **defense-in-depth, not a sandbox** — they raise the cost of an
accidental leak, they don't make exfiltration impossible. The content scan covers the
common outbound tools (`curl`/`wget`/web search & fetch); channels like `ssh`/`git push`/a
language runtime's own request, or a `$VAR`-referenced (non-literal) secret, are not
scanned. Treat them as the seatbelt; the brakes are `permissions.deny` on credential paths,
no auto-loaded MCP servers, and not running with `bypassPermissions`. The guards **fail
closed** if their pattern file is missing or corrupt.

Found a security issue? Please report it privately — see [`SECURITY.md`](SECURITY.md).

## Acknowledgments

- [PAI (Personal AI Infrastructure)](https://github.com/danielmiessler/PAI) by Daniel
  Miessler — early inspiration for the egress-guard and command-rewriting concepts.
- [trailofbits/claude-code-config](https://github.com/trailofbits/claude-code-config) —
  reference for the secure permission defaults and the maintainer-self-PR workflow.

The implementations here are our own. Built for
[Claude Code](https://docs.claude.com/en/docs/claude-code).

## License

[MIT](LICENSE).
