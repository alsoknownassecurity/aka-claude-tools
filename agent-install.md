# Install a aka-claude-tools profile — driven by your Claude Code instance

**You (Claude) are setting up a new isolated Claude Code config profile for the
user, from inside their already-authenticated session.** You **own the judgment**
— read the whole existing config, reason about dependencies, and migrate cleanly
where a static script would miss rough edges — and you **delegate the deterministic
mechanics to `install.sh`**, the repeatable engine: `./install.sh --apply` layers
the additions, `./install.sh --alias` creates the launcher alias. The user is
already authenticated, so there is no token/login dance.

**Do not write the user's shell rc yourself.** Creating the alias means editing
`~/.zshrc` / `~/.bashrc`, which the `command-guard` addition blocks (an agent writing
to startup files is a persistence vector). Always
create the alias by invoking `./install.sh --alias` — install.sh is the sole
sanctioned rc writer — never with an `echo >> ~/.zshrc` or an Edit of the rc.

Work through the steps below. **Confirm the plan before executing, and verify
after.** Never touch the user's default `~/.claude` config.

---

## 1. Gather preferences — ask the user; use the defaults only as fallback

Always let the user choose the folder and alias. Only apply a default if they
don't specify one:

- **Config folder name** — default `~/.claude-aka`
- **Alias** — default `aka` (if the user picks a custom folder, suggest the
  basename minus `.claude-`, e.g. `~/.claude-work` → `work`)
- The user may instead target their **default `~/.claude`** to rebuild it clean:
  move it to a timestamped backup (`~/.claude.backup-…`), recreate it with the
  selected additions, and migrate their picks from the backup. Skip the alias
  (plain `claude` launches it) and the auth/onboarding seed (`~/.claude.json`
  lives at `$HOME` and Keychain auth is keyed to the unchanged dir path — just
  copy a file-based `.credentials.json` back from the backup, plus any
  `aka-claude-tools.config`). Warn first: a running Claude Code session keeps
  working — it's loaded in memory — but may show hook errors while files are
  changed underneath it; that's normal, doesn't affect the install, and the next
  `claude` launch loads the rebuilt config.
- Which **additions** to layer on (read `config/additions.json` in this repo for
  the catalog + recommended defaults): secure base settings, leak-guard,
  command-guard (needs `bun`; also blocks writes to shell startup files),
  rtk-safe (inert until `rtk` is installed), responsive status line, shell-audit,
  the opt-out `/wrap-up` command, the opt-out secure-deep-research workflow, and the
  opt-out harness-pointer. Additions with a
  `skill` field are **directory copies**: copy the whole directory into
  `<dir>/skills/` (replace any existing copy so re-installs don't leave stale
  files). Additions with a `workflow` field are **file copies** into
  `<dir>/workflows/` — a `.js` there auto-registers as both the named workflow and
  its matching slash-command skill (Claude Code scans `<dir>/workflows/`).

## 2. Scan the existing config thoroughly

Inspect the user's current default config (`~/.claude`, or `$CLAUDE_CONFIG_DIR`
if set) and inventory what's migratable — **this is where you beat the script**:

- `settings.json` — permissions (allow/deny/ask), env, hooks, statusLine, model,
  and any **absolute paths** that will break under a new config dir.
- `.mcp.json` / MCP servers in settings — note any that reference local paths,
  binaries, or need their own auth.
- `agents/`, `skills/`, `commands/`, `output-styles/`, `hooks/`, `workflows/` — list items.
- `CLAUDE.md` **and any `@`-imports it references** — an import pointing outside
  the migrated set will dangle.
- `keybindings.json`, `plugins/` + `enabledPlugins`.

Present a clear inventory and let the user pick per category (individual items or
all). Flag cross-dependencies you notice (e.g. a skill that calls a hook, an
agent referenced in settings, an MCP server a command relies on).

## 3. Propose a migration plan, get approval

Summarize: target dir, alias, items to migrate, additions to add, and anything
that needs special handling (path rewrites, MCP auth, dangling imports). Wait for
the user's go-ahead.

## 4. Execute

- `mkdir -p` the target dir.
- Copy the **selected** items into the matching subdirs. Make migrated hooks
  executable.
- **Rewrite paths**: anywhere the migrated `settings.json` (or a copied file)
  references the OLD config dir — hook `command`s, `statusLine.command`, absolute
  globs — rewrite `<old config dir>` → `<new config dir>`. Don't miss non-hook
  absolute paths.
- **Stage the migrated settings** (don't hand-merge the additions): if you're
  migrating the user's `settings.json`, copy it into `<dir>` first (with the
  OLD→NEW path rewrites above). The engine layers the additions onto it next.
  - **Dangerous modes are the user's call**: if the migrated settings enable
    `permissions.defaultMode: bypassPermissions` or the skip-prompt flags
    (`skipDangerousModePermissionPrompt`, `skipAutoPermissionPrompt`), do NOT
    strip them. Tell the user these are on (Claude runs without permission prompts
    by default) and offer to turn them off — keep their setting unless they say so.
    This kit's own template never adds these.
- **Session history (opt-in):** ask the user whether to also migrate their
  session history — `history.jsonl`, `projects/`, `sessions/`, and `todos/`/`tasks/`
  (past conversations, input history, todo state). **Off by default**; copy these
  (merging into any existing dirs) only if they say yes. Even then, NEVER copy the
  secret-prone state: `.credentials.json`, `shell-snapshots/`, `session-env/`,
  `paste-cache/`, `file-history/`, `telemetry/` — those can capture exported tokens
  or pasted/edited secrets.
- **Layer the additions with the engine — do NOT hand-roll the settings merge or
  hook registrations.** Run:
  ```
  CT_CONFIG_DIR="<dir>" CT_ADDITIONS="<space-separated addition ids>" ./install.sh --apply
  ```
  This is the deterministic, idempotent, re-runnable mechanics. It places every
  selected addition's files and **unions their settings onto the `settings.json`
  already in `<dir>`** (the one you migrated), then handles every detail you'd
  otherwise get wrong by hand: strips `"$comment"`; reconciles retired permissions
  against `config/managed-permissions.json` (adopt new / retire dropped / keep the
  user's own); registers leak-guard **once** (`WebSearch|WebFetch` — web-only; Bash
  egress is owned by command-guard); registers command-guard with bun's **absolute**
  path (skipped with a notice if `bun`
  is absent); merges the read-only `rtk-allowlist.json` for rtk-safe (never a
  blanket `Bash(rtk:*)`); copies the shell-audit
  skill and chmods its `audit.sh`; and seeds `aka-claude-tools.config` when a
  config-driven hook is selected. **You own the judgment** (which additions, what to
  migrate); the **engine owns the mechanics**.
- **Statusline location (if the statusline is enabled):** offer to pin an exact
  location for weather (default: auto-detect by IP, city-level). Make clear that
  nothing is saved or collected — if they give a city/address, geocode it once
  (e.g. OpenStreetMap Nominatim or open-meteo geocoding) and store **only** the
  resulting coordinates as `preferences.location: {latitude, longitude, countryCode,
  regionCode}` in the profile's `settings.json` (`regionCode` is the abbreviated
  state/region the statusline displays, e.g. `CA`); don't keep the address text.
  Otherwise leave it to IP.
- **Onboarding**: seed `<dir>/.claude.json` with `oauthAccount`,
  `hasCompletedOnboarding`, `lastOnboardingVersion`, and related
  onboarding/terminal-setup flags copied from the user's own `~/.claude.json`
  (account metadata, no secrets — never tokens, projects, or history) so the new
  profile skips the first-launch onboarding prompt. `chmod 600` the result.
- **Auth** (you're already authenticated; just make the new profile inherit it):
  - `CLAUDE_CODE_OAUTH_TOKEN` / `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` in
    env → already covers every profile; nothing to copy.
  - `~/.claude/.credentials.json` present (Linux/file-based) → copy it in.
  - macOS Keychain → can't migrate (keyed per config dir); tell the user they'll
    `/login` once on first launch, or `claude setup-token` to cover all profiles.
- **Alias — create it with the engine, NEVER by editing the rc yourself.** Run:
  ```
  CT_CONFIG_DIR="<dir>" CT_ALIAS="<alias>" ./install.sh --alias
  ```
  install.sh is the sole sanctioned rc writer (see the top of this file): it
  reviews the rc *and every file it sources, recursively* (cycle-safe), then writes
  an **idempotent** managed block — re-running never duplicates, and each
  aka-managed profile keeps its own block. Handle its outcome:
  - **exit 0** — the alias is set (or already resolved to this dir, deduped). Done.
  - **non-zero exit** — `<alias>` is already taken by a **different** target;
    install.sh left it untouched. Pick another name and re-invoke, or skip the
    alias and give the user the `CLAUDE_CONFIG_DIR="<dir>" claude` invocation.

  Do **not** add the alias with `echo >> ~/.zshrc` or by editing the rc with the
  Edit tool — the `command-guard` addition blocks an agent writing to startup files,
  by design (and the secure-settings Edit/Write deny blocks the Edit tool path).
  Routing through `--alias` is the only path.

## 5. Verify, then report

- `settings.json` parses as a **single** valid object, with **no `"$comment"`**
  key and **none of the `config/managed-permissions.json` `.retired[]` rules** the
  user agreed to drop.
- Every hook path resolves inside the new dir and is executable; run each hook
  once with a sample tool-call JSON and confirm sensible exit codes.
- The alias is present in the rc; `.claude.json` has `oauthAccount`.
- Summarize what was migrated, what was added, the auth outcome, and any
  edge cases you handled or flagged. Tell the user to open a new shell and run
  the alias.

## Do not migrate

- **Secrets, always:** `.credentials.json` (except the auth step above),
  `telemetry/`, and the secret-prone session caches `shell-snapshots/`,
  `session-env/`, `paste-cache/`, `file-history/` — never copy these, even when the
  user opts into session-history migration (they can hold exported tokens or
  pasted/edited secrets).
- **Session/history, unless the user opts in:** `history.jsonl`, `projects/`,
  `sessions/`, `todos/`/`tasks/`, `.last-cleanup` default to *not migrated*; copy
  them only on the explicit opt-in described in the Execute step.
