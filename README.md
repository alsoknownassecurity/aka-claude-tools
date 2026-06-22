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
  secure defaults, two-layer egress guards (web queries + outbound Bash), a responsive status line, and a
  repo-agnostic `/wrap-up` command.

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

### Path A — let your authenticated Claude Code do it (recommended)

In your existing, already-logged-in Claude Code session:

```
Read agent-install.md and set up a new profile for me.
```

Path A **owns the whole lifecycle** — install, upgrade, and migrating a rich
existing config. Claude reads your whole config and reasons about the judgment
calls a script can't (which items to carry over, MCP servers, `CLAUDE.md`
`@`-imports and other absolute paths that need rewriting, skill↔hook
dependencies), then **invokes `install.sh` for the deterministic, repeatable
mechanics** — layering the additions (`--apply`) and creating the launcher alias
(`--alias`). You're already authenticated, so there's no token/login step. Spec:
[`agent-install.md`](agent-install.md).

`install.sh` is the **sole sanctioned writer of your shell rc**: Path A calls it
for the alias rather than editing `~/.zshrc` itself, so the `command-guard` addition
stays strict (it blocks an agent writing to your startup files — a persistence
vector — and only `install.sh --alias`, whose command string doesn't match, gets
through).

### Path B — terminal script (the engine; CI / no-agent installs)

```bash
./install.sh
```

`install.sh` is the deterministic engine. Run bare, it sets up a fresh profile —
prompting for the **config folder** (default `~/.claude-aka`), the **alias**
(default `aka`), and **which additions** to layer on (recommended pre-selected) —
or layers onto an existing folder in place. Migrating a rich existing config is
**Path A's job** (it reasons about it); pointing Path B at an existing dir simply
layers the additions on top.

Non-interactive (CI / scripted): `./install.sh --defaults` takes every default
(equivalent to `CT_NONINTERACTIVE=1`, which suppresses every prompt); add
`--no-auth-inherit` when the profile is for a *different* account. Set
`CT_ADDITIONS` to a space-separated list of addition ids (see
[`config/additions.json`](config/additions.json)) to install an **exact set**
(unknown id aborts; empty installs none), and `CT_CONFIG_DIR` to pick the folder:

> **Renamed ids:** the two guard additions are now `leak-guard` (was `leak-guard`)
> and `command-guard` (was `command-guard`). The old ids are **not** aliased — update
> any saved `CT_ADDITIONS` lists, or the install aborts on the unknown id.

```bash
CT_CONFIG_DIR="$HOME/.claude-aka" CT_ADDITIONS="secure-settings leak-guard wrap-up" \
  ./install.sh --defaults
```

**Engine modes** (what Path A invokes — also usable directly):

- `CT_CONFIG_DIR=<dir> CT_ADDITIONS="<ids>" ./install.sh --apply` — layer exactly
  those additions onto `<dir>` and exit: place files, union settings onto whatever
  is already there (including a `settings.json` Path A migrated in first), reconcile
  retired permissions, register hooks. No prompts, alias, or auth.
- `CT_CONFIG_DIR=<dir> CT_ALIAS=<name> ./install.sh --alias` — create/check the
  launcher alias for `<name> → <dir>`. **Idempotent** — re-running for the same
  dir+alias replaces the managed block, never duplicates it, and multiple
  aka-managed profiles each keep their own block. On a real name collision it exits
  non-zero (leaving your existing alias untouched) so the caller picks another name.

> **Existing profile?** Re-running `install.sh` for a folder that already exists
> **layers in place** — it never moves or wipes your dir. Re-registering the same
> addition won't duplicate it, and **unchecking** (deselecting) an addition on a
> re-run uninstalls it. For a clean rebuild, or to migrate a rich config faithfully,
> use **Path A**.
>
> **Upgrading a pre-rename profile?** Profiles created before the hook rename carry
> the old hook names (`command-guard.ts`, `leak-guard.sh`,
> `rtk-safe.hook.sh`). Run `./hook-rename.sh [CONFIG_DIR]` once
> **before** `./install.sh` to retire those old hooks and their stale `settings.json`
> registrations; the installer then places the renamed
> `command-guard`/`leak-guard`/`rtk-safe` hooks cleanly. (Newer profiles self-clean via
> the managed marker, so this one-time step is only for old ones.)

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
upgrade — a plain union never could. To remove an entire *addition*, **re-run the
installer without it** — deselect it in the menu, or drop it from your `CT_ADDITIONS`
list — and the installer deletes its files and prunes its `settings.json` registration
for you (the deselect path is idempotent: removing something already gone is a no-op).

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
| **leak-guard** | on | The always-on egress **floor** (pure bash + `jq`). `PreToolUse` guard on `WebSearch`/`WebFetch` **and outbound Bash commands**. Blocks queries/commands containing detected secrets (trufflehog, run local/detection-only — candidates are never sent to provider APIs for verification), Anthropic/AWS/GitHub/Slack/Stripe/OpenAI/webhook token shapes + SSH-key fragments (from the shared [`secret-patterns.json`](config/hooks/lib/secret-patterns.json)), pipe-to-shell (`… \| sh/bash/zsh`), and — if you configure them — your org's internal identifiers. Bash is **fast-gated**: only commands naming an outbound tool (`curl`/`wget`/`nc`/…, ~2% in real-world usage) are content-scanned — the other ~98% pay ~0 ms. Secrets passed as `$VAR` references aren't literal text and sail through; only pasted-literal values block. **Fails closed** if its pattern file is missing/corrupt. |
| **command-guard** | on | The bun **enhancement** layer (typed detector). `PreToolUse` guard on `Bash`. Denies a credential *value* paired with an outbound tool (from the shared [`secret-patterns.json`](config/hooks/lib/secret-patterns.json)), pipe-to-shell (`… \| sh/bash/zsh`), and **writes to shell startup files** (`~/.zshrc`, `~/.bashrc`, … — a persistence vector the secure-settings Edit/Write deny can't reach through a Bash `echo >> ~/.zshrc` redirection; legit alias writes go through `install.sh --alias`); alerts on `nc`/`socat`/`sendmail`/env-dump/inline-interpreter. **Fails closed** on outbound if the pattern file is corrupt. **Requires `bun`** — a hard dependency: selecting command-guard **aborts the install** if `bun` is absent, rather than shipping a default-on security guard silently disabled. Don't want `bun`? Deselect command-guard — `leak-guard` alone still enforces secret content + pipe-to-shell. |
| **rtk-safe** | on | `PreToolUse` rewrite on `Bash`. Transparently rewrites `git`/`gh`/`cat`/`ls`/`npm`/`docker`/… to compact `rtk` equivalents for token savings — no `rtk init` needed (see [How RTK rewriting is wired](#how-rtk-rewriting-is-wired)). The rewritten command still goes through your normal permission rules — the hook never auto-approves anything. Because the rewrite changes the command string (`git status` → `rtk git status`), your existing allow rules stop matching it, so this addition also installs a **strictly read-only, evidence-based allowlist** ([`config/rtk-allowlist.json`](config/rtk-allowlist.json)): `rtk read`/`find`/`ls`/`diff`/`wc` plus the strictly local read-only `git` forms (`status`/`diff`/`log`/`show`/`branch`/`stash list`/`stash show`) — only forms with real production usage in the ~13K-command sample; nothing speculative. Mutating/**outbound** forms (`rtk curl`, `rtk aws`, `rtk git push`, and `rtk git fetch` — fetch contacts a remote) still prompt — deliberately **not** a blanket `Bash(rtk:*)`, which would amount to a general Bash allow since rtk fronts curl/aws/psql/docker. (`rtk find` is safe to allow: it rejects `-exec`/`-delete`.) The rewrite also **won't convert `cat`/`head` reads of credential paths** (`~/.ssh`, `.env`, `~/.aws`, …) into `rtk read` — that would slip them past the secure-settings `Read(...)` denies, so those stay as the original command and keep prompting/denying. **Inert until you install `rtk`** (self-skips if absent). |
| **Responsive status line** | on | Width-adaptive status line: **repo + branch**, context, usage, and weather. Weather location auto-detects by IP (city-level); you can optionally **pin an exact location at install** (your entry is geocoded once via OpenStreetMap, only the resulting coordinates are stored locally — the text isn't kept and nothing is collected). Resolves its own config dir. |
| **`/wrap-up`** | off | End-of-session handoff that **prepares, doesn't auto-commit**: defers to repo conventions, summarizes, verifies (stops on failure), stages intentionally with a secret/artifact scan, **drafts** a conventional commit message for *you* to review and commit, surfaces loose ends. **Multi-user aware**: won't touch staged changes it didn't make, stops over an in-progress rebase/merge, won't stage files mixing this session's work with someone else's (proposes the `git add` commands instead), and on `main`/protected branches proposes a feature branch rather than committing there. Never commits, merges, or pushes unless asked. |
| **shell-audit** | on | Read-only auditor skill (`/shell-audit`). Walks your shell rc and every file it `source`s (cycle-safe) and flags: hardcoded credentials (values redacted), persistence-suspicious patterns (pipe-to-shell, eval-of-fetched, `DYLD`/`LD_PRELOAD`, writes into other rc files), duplicate or dangling aliases, and git-baseline drift. A detective tripwire — nothing is modified; not a substitute for launchd/cron/ssh review. |
| **harness-pointer** | off | `PreToolUse` guard on `Bash` that intercepts org-configured commands and points the agent to the right approach for your environment (e.g. `gh` → `git` on a self-hosted VCS). Guidance, not a security boundary. Ships **disabled and empty** — most people want every CLI. |
| **secure-deep-research** | off | Privacy-aware deep-research workflow (`/secure-deep-research`): fan-out web search → fetch → 3-vote adversarial verify → cited synthesis. The Scope agent classifies privacy sensitivity (conservative); sensitive topics are query-redacted, **gated** for confirmation before any external query fires, fan-out-reduced, and routed through a self-hosted SearXNG MCP server. Normal topics use `WebSearch`/`WebFetch` at full fan-out. The sensitive-topic path needs a self-hosted SearXNG MCP server configured; without it, only the normal path works. |

Catalog: [`config/additions.json`](config/additions.json).

## What the egress guards do and don't catch

The two egress guards are **defense-in-depth, not a sandbox** — they raise the
cost of an accidental leak, they don't make exfiltration impossible. They're two
layers: `leak-guard` is the always-on bash **floor**; `command-guard` is the bun
**enhancement**. Both read one shared pattern source
([`config/hooks/lib/secret-patterns.json`](config/hooks/lib/secret-patterns.json)
— bash via `jq`, TypeScript via `JSON.parse`) and are checked by a single test
corpus run against both, so their detection can't quietly drift apart. Be honest
with yourself about the edges:

- **The content scan is scoped to a fixed set of outbound tools.** Both `leak-guard`'s
  fast gate and `command-guard` only inspect a command for secret *content* when it
  names `curl`/`wget`/`nc`/`ncat`/`socat`/`fetch`. Commands that egress by other
  means are **not scanned**: `ssh`/`scp`/`sftp`/`rsync`, `git push` to a remote,
  `aws s3`, bash's `/dev/tcp` redirection, a language runtime making the request
  itself (`python -c 'requests.post(…)'`, `node -e`, `perl -e`), or a bare URL with
  no recognized tool name on the line. A literal secret on any of those channels
  will pass. This is the deliberate ~2%-scan tradeoff from design goal 2 — it keeps
  everyday commands at ~0 ms — so the content scan is a backstop against careless
  paste-and-run, not a containment boundary. (Pipe-to-shell, `… | sh|bash|zsh`, is
  checked on **every** Bash command by **both** guards — so that protection survives
  even when bun is absent.)
- **Detection requires a real key value, and is heuristic.** A pattern fires only on
  an actual key-*shaped* value, not a bare prefix or the mere words — so analysis
  text that merely names a credential type passes. It does **not** catch
  base64/hex-encoded, split, or `$VAR`-referenced secrets (the last by design — a
  `$VAR` carries no literal to scan), nor indirections like `… | sudo bash` or
  `curl -o /tmp/x && bash /tmp/x`.
- **Fail behavior is closed where it counts.** If the shared pattern file is missing
  or corrupt, the guards **fail closed** — they block the scannable subset (outbound
  Bash + web egress) rather than silently allow, while still letting benign
  non-outbound commands through; a bad `CT_EGRESS_PATTERNS` regex **warns loudly**
  instead of degrading to allow. The remaining fail-*open* paths are the ones we
  don't own and surface explicitly: a missing `trufflehog` (Tier 1) degrades to the
  regex tiers with a warning, and `command-guard` failing to parse an unexpected input
  shape allows it **loudly** — the bash floor already scanned the same call, so it's
  not a silent hole.

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
- **trufflehog** (for **leak-guard**, optional) — offered via `brew`; degrades to
  regex tiers without it.
- **rtk** (for **rtk-safe**) — offered when that addition is selected:
  `brew install rtk`, else `cargo install --git`, else rtk's official installer
  ([rtk-ai/rtk](https://github.com/rtk-ai/rtk)); the hook stays inert until present.

## Layout

```
aka-claude-tools/
├── agent-install.md            # Path A — lifecycle spec your Claude Code executes
├── agent-uninstall.md          # agent-driven teardown — delegates to uninstall.sh
├── install.sh                  # the engine — layering (--apply) + alias (--alias)
├── uninstall.sh                # one-shot teardown (env-isolated, marker-based)
├── config/                     # the payload layered into a profile
│   ├── settings.base.json      # secure base settings
│   ├── rtk-allowlist.json      # read-only rtk allow rules (with RTK rewriting)
│   ├── additions.json          # catalog (drives the menu)
│   ├── hooks/                  # leak-guard, command-guard (bun),
│   │                           #   rtk-safe (rtk), statusline, harness-pointer
│   ├── commands/wrap-up.md
│   ├── skills/shell-audit/     # shell startup-file security audit
│   └── workflows/secure-deep-research.js
└── shared/
    ├── aka-claude-tools.config.example
    └── lib/common.sh           # installer helpers
```

## Upgrading

`git pull` this repo, then **re-run against the profile you already use** (e.g.
`~/.claude-aka`). The upgrade **layers in place** — it never moves or wipes your
dir:

- The **current** kit hooks/commands/skills are re-placed at this version (a
  re-run refreshes the kit-managed files), and your selected additions are
  re-layered.
- Your **own** settings are preserved: permission rules you added are unioned and
  never dropped; the kit's **own** rules are *reconciled* (new ones adopted, ones
  the kit has since **retired** removed) — your rules are untouched.
- **Deselecting** an addition on a re-run uninstalls it (its files + settings
  registrations are pruned).

The easiest upgrade is **Path A** — ask your authenticated Claude Code to read
`agent-install.md`; it re-applies the kit (via `install.sh --apply`) and reasons
about anything in your config a script can't. For a guaranteed-clean rebuild, or
to migrate a rich config (MCP servers, `@`-imports), Path A is the route.

> **No version tracking.** The kit records no installed-version number, so it can't
> detect a *downgrade*. An installer only retires the additions *it* knows about, so
> re-running an **older** kit over a profile a **newer** kit set up keeps that newer
> kit's entries in place (the old kit has never heard of them). This is harmless but
> can leave additions the older kit wouldn't ship on its own.

## Uninstall

Run the one-shot uninstaller:

```sh
./uninstall.sh                      # discover installed profiles and pick one
./uninstall.sh ~/.claude-work       # or name the profile directly
# add --yes to skip the confirmation
```

With no argument it scans the managed alias blocks in your shell rc and lets you
**pick which profile to remove** (a lone one is preselected); name a path
explicitly to skip the prompt. It removes the config folder **and** every managed
alias block the kit wrote for that profile — matched by our
`# >>> aka-claude-tools managed: … >>>` markers and the dir they point at, so it
finds them whatever the alias was named and never touches blocks for other
profiles or anything outside our markers.

Because it's a destructive `rm -rf`, it is deliberately strict about its target:
it **never** reads the ambient `$CLAUDE_CONFIG_DIR` as the dir to delete (it's
used only to **refuse** removing the profile the current session is running inside,
which is also excluded from the pick-list), `--yes` won't guess between several
discovered profiles, and removing the default `~/.claude` always requires an
interactive confirmation. Prefer running it from a plain shell.

From inside an authenticated session you can instead ask Claude to
`Read agent-uninstall.md and remove my <name> profile` — it audits what's
irreplaceable, offers a backup, then delegates the actual removal to `uninstall.sh`
(so the same guards apply). It will not remove the profile the current session is
running in — run that from a plain shell.

Or do it by hand: `rm -rf ~/.claude-aka` and delete the
`# >>> aka-claude-tools managed: <alias> >>>` block from your shell rc. Your default
`~/.claude` is never touched by the installer.

## Security

Found a security issue? Please report it privately — see [`SECURITY.md`](SECURITY.md).
Note the egress guards are **defense-in-depth, not a sandbox** (see [What the egress
guards do and don't catch](#what-the-egress-guards-do-and-dont-catch)).

## Acknowledgments

aka-claude-tools is an independent toolkit — installed on its own, with no other
framework required. Its design was informed by earlier work in the Claude Code
security and tooling space, with thanks to:

- [PAI (Personal AI Infrastructure)](https://github.com/danielmiessler/PAI) by
  Daniel Miessler — early inspiration for the Bash egress-guard and command-rewriting
  hook concepts.
- [trailofbits/claude-code-config](https://github.com/trailofbits/claude-code-config)
  — reference for the secure permission defaults and the maintainer-self-PR workflow.

The implementations here are our own. Built for
[Claude Code](https://docs.claude.com/en/docs/claude-code).

## License

[MIT](LICENSE).
