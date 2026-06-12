# aka-claude-tools

The must-have additions for a fresh Claude Code install, plus a one-command
installer that sets up **isolated config folders** you launch by alias.

From [alsoknownassecurity](https://github.com/alsoknownassecurity), MIT-licensed.
Clone it, run the installer, pick what you want.

---

## Why

Claude Code reads its entire configuration from `$CLAUDE_CONFIG_DIR` (default
`~/.claude`). Point it somewhere else and you get a fully independent profile —
own settings, hooks, agents, sessions, history. `aka-claude-tools` leans on that to
give you:

- **Per-context profiles you launch by name.** A work profile, a throwaway
  profile, a locked-down profile — each its own folder, each its own alias.
- **A small set of genuinely useful additions** layered onto any profile:
  secure defaults, a web-egress secret guard, a responsive status line, a
  repo-agnostic `/wrap-up` command, and a loop-designer skill that compiles a
  spec into a minimal autonomous-run kickoff prompt.

The default profile the installer offers is `~/.claude-aka`, launched with the
alias **`aka`**.

## Design goals

Everything in this kit is built against three rules:

1. **Pick-and-choose additions.** Every addition is independent and optional —
   the installer is a menu, not a bundle. Nothing assumes anything else is
   installed, opt-in items ship disabled and empty, and your default `~/.claude`
   is never touched unless you explicitly target it.
2. **Zero hot-path friction.** Guards must be invisible until the moment they
   matter. Expensive checks run only on calls that can actually egress (~2% of
   real Bash traffic); everything else pays ~0 ms. Read-only commands are
   pre-allowed so security never costs you prompts on safe operations — and
   nothing mutating or outbound is ever auto-approved to buy convenience.
3. **Every decision backed by real-world samples.** The rewrite table, the
   allowlist, and the latency gates are tuned on ~13K production agent commands
   — features that consistently failed or changed semantics in practice were
   removed, not papered over, and nothing speculative ships. When new usage
   data says otherwise, the kit changes.

## Quick start

```bash
git clone git@github.com:alsoknownassecurity/aka-claude-tools.git
cd aka-claude-tools
```

Two ways to install — pick one:

### Path A — let your authenticated Claude Code do it (recommended)

In your existing, already-logged-in Claude Code session:

```
Read agent-install.md and set up a new profile for me.
```

Claude reads the whole existing config and reasons about migration — catching
rough edges the script can't (MCP servers, `CLAUDE.md` `@`-imports, non-hook
absolute paths, skill↔hook dependencies). You're already authenticated, so
there's no token/login step. Spec: [`agent-install.md`](agent-install.md).

### Path B — terminal script

```bash
./install.sh
```

Deterministic and fast. Interactive prompts:

1. **Which config folder** to create/update (default `~/.claude-aka`).
2. **Which alias** launches it (default `aka`).
3. **Migrate from an existing config?** — defaults to your **live** Claude Code
   config dir (`$CLAUDE_CONFIG_DIR`, or `~/.claude` when unset), but you can point
   it at any other folder or a backup. It scans each category (agents, skills,
   commands, output-styles, hooks) and lets you pick exactly what to bring over
   (`1 3`, ranges `1-3`, or `all`); plus settings.json (hook paths auto-rewritten,
   symlinks dereferenced) and `CLAUDE.md`. If your settings already enable
   `bypassPermissions` / skip-prompt flags, the installer tells you and offers to
   turn them off — but **keeps your setting by default**: the kit's own template
   never adds them, and your existing choice is yours to keep. Optionally migrate
   **session history** too (past conversations, input history, todos) — an explicit
   prompt, **off by default**. Secrets are **never** migrated, and neither are the
   shell/env and paste caches that can capture them (`shell-snapshots/`,
   `session-env/`, `paste-cache/`, `file-history/`, `.credentials.json`).
4. **Which additions** to layer on (recommended ones pre-selected).

Non-interactive: `./install.sh --defaults` takes every default (clean profile, no migration).

> **Rebuild your default `~/.claude`:** enter `~/.claude` as the target folder and
> the installer offers to move it to a timestamped backup (`~/.claude.backup-…`),
> recreate it clean with the additions, and migrate your picks back from the
> backup. No alias is written — plain `claude` already launches it — and your
> login survives: `~/.claude.json` lives at `$HOME`, macOS Keychain auth is keyed
> to the unchanged dir path, and a file-based `.credentials.json` is copied back.
> A Claude Code session that's already running keeps working (it's loaded in
> memory), though it may show hook errors while files are changed underneath it —
> that's normal and doesn't affect the install. The next time you launch `claude`,
> the newly-configured setup loads. Sessions/history stay in the backup; delete it
> once you're happy. (Decline the backup and the installer layers the additions
> onto `~/.claude` in place instead.)
>
> **Rebuilding any other existing profile works the same way** — target any config
> dir that already exists (e.g. `~/.claude-work`) and you get the same offer: back
> up → rebuild clean → migrate your picks back. The difference for `~/.claude` is
> just that it needs no alias and defaults to *yes*; every other existing profile
> defaults to **layer-in-place** (so an idempotent re-run to add an addition never
> wipes it — choose to rebuild only when you mean to). Account metadata and a
> file-based `.credentials.json` are restored from the backup. This is the clean
> upgrade path as the kit grows.

---

Either path writes an alias into your shell rc inside a managed block:

```bash
# >>> aka-claude-tools managed: aka >>>
alias aka='CLAUDE_CONFIG_DIR="$HOME/.claude-aka" claude'
# <<< aka-claude-tools managed: aka <<<
```

Open a new shell (or `source ~/.zshrc`) and run **`aka`**. Re-run either path
any time to add another profile or update an existing one — both are idempotent
(re-registering the same addition won't duplicate it). **Your own settings are
preserved**: permission rules you (or a migration) added are never dropped. The
kit's **own** permission rules are *reconciled* on a re-run — it shows you a
per-rule diff and, by default, adopts this version's set: new denies/allows are
added, and ones the kit has since **retired are removed** (the history lives in
[`config/managed-permissions.json`](config/managed-permissions.json); you can keep
or skip any rule individually, and a rule the kit never shipped is always left
alone). That's how a trimmed-down deny propagates to an existing profile on
upgrade — a plain union never could. To remove an entire *addition* (its
hook/command/skill), delete its files and `settings.json` registration by hand, or
rebuild the profile from scratch.

## Authentication — no re-login

A fresh config dir starts with no auth state, so by default Claude Code would run
the `/login` onboarding flow on the new profile's **first launch**. The installer
saves you from that by inheriting your existing login (disable with
`--no-auth-inherit` if the profile is for a *different* account):

- **Onboarding metadata** — it seeds the new `.claude.json` with your `oauthAccount`
  + onboarding flags, copied from your own `~/.claude.json` (your account metadata,
  no secrets, same machine). This is what stops the per-launch onboarding prompt.
- **Credentials** — the installer detects the active method (Claude Code's precedence order) and inherits it where possible:
  - **Env token** (`ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, or `CLAUDE_CODE_OAUTH_TOKEN`) → already covers *every* profile; nothing to copy. (`claude setup-token` generates the OAuth one — the cleanest multi-profile setup.)
  - **`~/.claude/.credentials.json`** (Linux / file-based) → copied into the new profile.
  - **macOS Keychain** (OAuth `/login`, no env token) → **can't migrate between configs** — Claude Code keys Keychain auth per config dir. You'll **authenticate once** when you first launch the new alias. To avoid per-profile logins entirely, use `claude setup-token`.

## What's in the box

| Addition | Default | What it does |
|----------|:------:|--------------|
| **Secure base settings** | on | Deny-reads on credential paths (`~/.ssh`, `~/.aws`, `.env`, keychains, crypto wallets, …); deny-**edit/write** on shell rc (`~/.zshrc`, `~/.bashrc`, … — blocks a persistence vector); `enableAllProjectMcpServers: false` (a cloned repo's `.mcp.json` can't auto-load untrusted MCP servers); telemetry/error-reporting/feedback off while **auto-update stays on** (see [Telemetry & updates](#telemetry--updates)); empty `attribution` (no auto Claude co-author). Deliberately **omits** `bypassPermissions` — you opt into risk yourself. |
| **Web egress sanitizer** | on | `PreToolUse` guard on `WebSearch`/`WebFetch` **and outbound Bash commands**. Blocks queries/commands containing detected secrets (trufflehog, run local/detection-only — candidates are never sent to provider APIs for verification), Anthropic/AWS/GitHub/Slack token shapes, SSH-key fragments — and, if you configure them, your org's internal identifiers (which otherwise would never be checked on the Bash channel). Bash is **fast-gated**: only commands containing an outbound tool (`curl`/`wget`/`nc`/…, ~2% in real-world usage) are scanned — the other ~98% pay ~0 ms, so everyday commands feel nothing. Secrets passed as `$VAR` references aren't literal text and sail through; only pasted-literal secrets block. |
| **command-guard** | on | `PreToolUse` guard on `Bash`. Denies credential exfil (key shape + outbound tool) and pipe-to-shell (`curl … \| bash`); alerts on `nc`/`socat`/`sendmail`/env-dump/inline-interpreter. **Requires `bun`** — skipped at install if absent. |
| **RTK command rewriting** | on | `PreToolUse` rewrite on `Bash`. Transparently rewrites `git`/`gh`/`cat`/`ls`/`npm`/`docker`/… to compact `rtk` equivalents for token savings — no `rtk init` needed (see [How RTK rewriting is wired](#how-rtk-rewriting-is-wired)). The rewritten command still goes through your normal permission rules — the hook never auto-approves anything. Because the rewrite changes the command string (`git status` → `rtk git status`), your existing allow rules stop matching it, so this addition also installs a **strictly read-only, evidence-based allowlist** ([`config/rtk-allowlist.json`](config/rtk-allowlist.json)): `rtk read`/`find`/`ls`/`diff`/`wc` plus the strictly local read-only `git` forms (`status`/`diff`/`log`/`show`/`branch`/`stash list`/`stash show`) — only forms with real production usage in the ~13K-command sample; nothing speculative. Mutating/**outbound** forms (`rtk curl`, `rtk aws`, `rtk git push`, and `rtk git fetch` — fetch contacts a remote) still prompt — deliberately **not** a blanket `Bash(rtk:*)`, which would amount to a general Bash allow since rtk fronts curl/aws/psql/docker. (`rtk find` is safe to allow: it rejects `-exec`/`-delete`.) The rewrite also **won't convert `cat`/`head` reads of credential paths** (`~/.ssh`, `.env`, `~/.aws`, …) into `rtk read` — that would slip them past the secure-settings `Read(...)` denies, so those stay as the original command and keep prompting/denying. **Inert until you install `rtk`** (self-skips if absent). |
| **Responsive status line** | on | Width-adaptive status line: **repo + branch**, context, usage, and weather. Weather location auto-detects by IP (city-level); you can optionally **pin an exact location at install** (your entry is geocoded once via OpenStreetMap, only the resulting coordinates are stored locally — the text isn't kept and nothing is collected). Resolves its own config dir. |
| **`/wrap-up` command** | on | End-of-session handoff that **prepares, doesn't auto-commit**: defers to repo conventions, summarizes, verifies (stops on failure), stages intentionally with a secret/artifact scan, **drafts** a conventional commit message for *you* to review and commit, surfaces loose ends. **Multi-user aware**: won't touch staged changes it didn't make, stops over an in-progress rebase/merge, won't stage files mixing this session's work with someone else's (proposes the `git add` commands instead), and on `main`/protected branches proposes a feature branch rather than committing there. Never commits, merges, or pushes unless asked. |
| **loop-designer skill** | on | Compiles a finished spec/plan — any doc with verifiable acceptance criteria, constraints, and human approval gates — into the **smallest kickoff prompt that runs it well** in a fresh orchestrator session: a ~7-line must-have discipline core (verify-yourself, context hygiene, don't self-sign gates) plus an evidence-based catalog of opt-in guardrails distilled from real multi-hour autonomous runs. Also persists the result to a canonical `EXECUTION-PROMPT.md` (provenance-stamped, staleness-guarded) and includes a **Harden** mode that slims over-specified hand-written kickoff prompts. Pure skill files — no hooks, no runtime cost. |
| **Harness pointer** | off | `PreToolUse` guard on `Bash` that intercepts org-configured commands and points the agent to the right approach for your environment (e.g. `gh` → `git` on a self-hosted VCS). Guidance, not a security boundary. Ships **disabled and empty** — most people want every CLI. |

Catalog: [`config/additions.json`](config/additions.json).

## What the egress guards do and don't catch

The two egress guards are **defense-in-depth, not a sandbox** — they raise the
cost of an accidental leak, they don't make exfiltration impossible. Be honest
with yourself about the edges:

- **The Bash scan is scoped to a fixed set of outbound tools.** Both the web-egress
  sanitizer's fast gate and command-guard only inspect a command when it names
  `curl`/`wget`/`nc`/`ncat`/`socat`/`fetch` or a literal `http://` URL. Commands
  that egress by other means are **not scanned**: `ssh`/`scp`/`sftp`/`rsync`,
  `git push` to a remote, `aws s3`, bash's `/dev/tcp` redirection, a language
  runtime making the request itself (`python -c 'requests.post(…)'`,
  `node -e`, `perl -e`), or an `https://` URL with no recognized tool name on the
  line. A literal secret on any of those channels will pass. This is the
  deliberate ~2%-scan tradeoff from design goal 2 — it keeps everyday commands at
  ~0 ms — but it means the Bash guard is a backstop against careless paste-and-run,
  not a containment boundary.
- **Detection is heuristic and regex-based.** It catches *literal* secrets and
  known token shapes; it does not catch base64/hex-encoded, split, or
  `$VAR`-referenced secrets (the last is by design — a `$VAR` carries no literal
  to scan). command-guard's pipe-to-shell check matches `… | sh|bash|zsh` but
  not indirections like `… | sudo bash` or `curl -o /tmp/x && bash /tmp/x`.
- **Both fail open.** A parse error, a missing `trufflehog` (Tier 1), or an
  unhandled input shape results in *allow*, never a spurious block. That keeps the
  hot path unbreakable at the cost of not being a hard gate.

The sturdier controls are elsewhere: `permissions.deny` on credential paths
(secure base settings), `enableAllProjectMcpServers: false`, and not running with
`bypassPermissions`. Treat the egress guards as the seatbelt, not the brakes.

## How RTK rewriting is wired

**You don't need to run `rtk init`.** rtk's own setup (`rtk init` / `rtk init -g`)
injects usage instructions for the assistant — this kit doesn't use that
mechanism. Instead the rtk-safe hook invokes `rtk` directly: it
intercepts each Bash call *before execution* and rewrites the command to its
`rtk` equivalent, so the agent gets compact output without ever being taught to
type `rtk` itself. If rtk's CLI prints `[warn] No hook installed — run 'rtk init
-g'`, ignore it — rtk-safe **is** the hook here.

The rewrite table and the read-only allowlist are **tuned on ~13K real-world
agent commands** (90 days of production agent usage): rewrites that deliver the
bulk of the token savings are kept and pre-allowed where strictly read-only;
rewrites that consistently failed or changed command semantics in practice
(notably `grep`/`rg`) are turned off rather than left to fall back. Mutating and
egress commands are never pre-allowed, tuned or not.

**Why it's worth a hook** — from that 90-day sample:

| Metric | Value |
|---|---|
| Commands routed through rtk | ~12.7K |
| Tokens saved | **17.6M of 23.6M (74.6%)** |
| Added latency | ~83 ms avg per command |
| Biggest absolute saver | file reads (`cat` → `rtk read`) — ~14M tokens, ~80% of all savings |
| Best per-call compaction | `find` ~79%, `ls` ~65%, `wc` ~87% per command |

In context terms: that's tens of full 200K context windows of raw command output
that never reached the model — less compaction, fewer context overflows, and
materially lower usage burn on subscription limits. The savings concentrate in
exactly the read-only inspection commands an agent runs constantly, which is why
those are also the ones pre-allowed.

## Telemetry & updates

The secure base settings turn off three outbound streams **and deliberately leave
the auto-updater on** so you stay patched:

| env var | what it disables |
|---|---|
| `DISABLE_TELEMETRY` | usage analytics (Statsig) |
| `DISABLE_ERROR_REPORTING` | crash/error reporting (Sentry) |
| `DISABLE_FEEDBACK_COMMAND` | the in-app feedback command / session survey |

**Want controlled updates instead?** Claude Code's umbrella var
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` is the equivalent of the three above
**plus `DISABLE_AUTOUPDATER`** — and it auto-disables any *future* nonessential
traffic Anthropic adds. Use it if you'd rather update on your own cadence
(`claude update`) — e.g. to keep an agent with filesystem access from silently
swapping its own binary. Swap your profile's `settings.json` `env` to:

```json
"env": { "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1" }
```

## Org-specific config (opt-in)

Two hooks can match **your** internal identifiers, but ship knowing nothing about
them. To opt in, edit `aka-claude-tools.config` in your config folder (the installer
drops a commented template):

```bash
# block internal hostnames/IPs/paths/usernames from leaking into web queries
CT_EGRESS_PATTERNS='corp\.internal|10\.42\.[0-9]+\.[0-9]+|/Users/jdoe/'

# steer the agent away from a banned/irrelevant CLI
CT_BLOCKED_CMDS="gh"
CT_BLOCKED_HINT="Use plain git — our remote is self-hosted."
```

Template: [`shared/aka-claude-tools.config.example`](shared/aka-claude-tools.config.example).
Nothing org-specific is ever committed to this repo.

## Requirements

The installer **checks each dependency and offers to install it** (with your
confirmation) via your detected package manager — `brew`, `apt`/`dnf`/`pacman`,
or `npm` — when you select the addition that needs it. **If you have no package
manager at all, it offers to install Homebrew first** (the official `brew.sh`
installer, interactive, with consent), then the dependency. Non-interactive runs
(`--defaults`) never install anything — a missing optional dependency is warned
about and skipped, and a missing required one aborts with the manual install
command:

- **jq** (required) — drives the settings merge; offered at startup if missing.
- **Claude Code** — the `claude` CLI on your PATH.
- **bun** (for **command-guard**) — offered via `brew`/`npm` when that addition
  is selected. (No `curl … | bash` auto-run — our own command-guard blocks
  pipe-to-shell; if you have neither brew nor npm, install from https://bun.sh/install.)
- **trufflehog** (for **web-egress**, optional) — offered via `brew`; degrades to
  regex tiers without it.
- **rtk** (for **RTK command rewriting**) — offered when that addition is selected:
  `brew install rtk`, else `cargo install --git`, else rtk's official installer
  ([rtk-ai/rtk](https://github.com/rtk-ai/rtk)); the hook stays inert until present.

## Layout

```
aka-claude-tools/
├── agent-install.md            # Path A — spec your Claude Code instance executes
├── install.sh                  # Path B — terminal installer
├── config/                     # the payload layered into a profile
│   ├── settings.base.json      # secure base settings
│   ├── rtk-allowlist.json      # read-only rtk allow rules (with RTK rewriting)
│   ├── additions.json          # catalog (drives the menu)
│   ├── hooks/                  # leak-guard, command-guard (bun),
│   │                           #   rtk-safe (rtk), statusline, harness-pointer
│   ├── commands/wrap-up.md
│   └── skills/loop-designer/   # spec → minimal autonomous-run kickoff prompt
└── shared/
    ├── aka-claude-tools.config.example
    └── lib/common.sh           # installer helpers
```

## Upgrading

`git pull` this repo, then **re-run the installer against the profile you already
use** (your existing aka-claude-tools-enhanced config — e.g. `~/.claude-aka`, or even
`~/.claude` itself). Because the target already exists, the installer offers to
**back it up, rebuild it clean with the latest additions, and migrate your config
back from the backup** — so you end up with a freshly-upgraded,
aka-claude-tools-enhanced Claude Code instead of additions piled on top of old ones:

- The **current** hooks/commands replace whatever the old install left behind (the
  rebuild starts clean, then layers today's additions).
- Your **own** settings, agents, skills, commands, and `CLAUDE.md` come back via
  the migrate step (pick what you want); secure denies are unioned, and if your
  settings enable `bypassPermissions` the installer surfaces it and keeps it
  unless you tell it otherwise.
- Your **login survives** — account metadata and a file-based `.credentials.json`
  are restored from the backup, Keychain auth is keyed to the unchanged dir path.
- The **backup** (`<dir>.backup-…`) keeps sessions/history and anything you didn't
  migrate; delete it once you're happy.

Choosing the rebuild is opt-in — for any profile other than `~/.claude` it defaults
to *layer-in-place*, so a quick re-run that just adds one addition never wipes your
dir. Pick the rebuild when you want the clean upgrade. (Prefer **Path A** if your
config has MCP servers or `@`-imports the script can't reason about.)

## Uninstall

Delete the config folder (`rm -rf ~/.claude-aka`) and remove the
`# >>> aka-claude-tools managed: <alias> >>>` block from your shell rc. Your default
`~/.claude` is never touched by the installer.

## Security

Found a security issue? Please report it privately — see [`SECURITY.md`](SECURITY.md).
Note the egress guards are **defense-in-depth, not a sandbox** (see [What the egress
guards do and don't catch](#what-the-egress-guards-do-and-dont-catch)).

## Acknowledgments

The command-guard and RTK rewriting additions are ported from

notice. Built for [Claude Code](https://docs.claude.com/en/docs/claude-code).

## License

[MIT](LICENSE). 
