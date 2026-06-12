# Install a aka-claude-tools profile — driven by your Claude Code instance

**You (Claude) are setting up a new isolated Claude Code config profile for the
user, from inside their already-authenticated session.** This path is an
intelligent alternative to `install.sh`: you can read the whole existing config,
reason about dependencies, and migrate cleanly where a static shell script would
miss rough edges. The user is already authenticated, so there is no token/login
dance to perform.

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
  the catalog + recommended defaults): secure base settings, web-egress
  sanitizer, command-guard (needs `bun`), RTK command rewriting (inert until
  `rtk` is installed), status line, `/wrap-up`, the loop-designer skill, and the
  opt-in harness-pointer. Additions with a `skill` field are **directory copies**:
  copy the whole directory into `<dir>/skills/` (replace any existing copy so
  re-installs don't leave stale files).

## 2. Scan the existing config thoroughly

Inspect the user's current default config (`~/.claude`, or `$CLAUDE_CONFIG_DIR`
if set) and inventory what's migratable — **this is where you beat the script**:

- `settings.json` — permissions (allow/deny/ask), env, hooks, statusLine, model,
  and any **absolute paths** that will break under a new config dir.
- `.mcp.json` / MCP servers in settings — note any that reference local paths,
  binaries, or need their own auth.
- `agents/`, `skills/`, `commands/`, `output-styles/`, `hooks/` — list items.
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
- **Merge settings**: start from the user's settings (if migrating it), then
  layer the selected additions from this repo's `config/` (their hook paths must
  point at the NEW dir). When merging arrays, **union** `permissions.deny/allow/ask`
  and the `hooks.*` event arrays — never drop the user's existing entries. The
  result must be **one valid JSON document**.
  - **Strip maintainer comments**: the addition files (`config/settings.base.json`,
    `config/rtk-allowlist.json`) carry a top-level `"$comment"` array of notes for
    maintainers. Drop it — never write `"$comment"` into the profile's
    `settings.json` (Claude Code would flag it as an unknown key).
- **Reconcile retired permission rules (upgrade/re-install)**: a plain union can
  *add* rules but never *remove* one the kit has dropped, so an existing profile
  would keep stale denies forever. When the target already has a `settings.json`
  (or you're migrating one), reconcile against this repo's
  `config/managed-permissions.json` (`.retired.deny/allow/ask`):
  - **New rules** in the selected additions but not in the profile → **adopt by
    default**.
  - **Rules listed in `.retired[]`** that are present in the profile but no longer
    in the current additions → these are rules the kit shipped before and has since
    dropped → **retire (remove) by default**.
  - **Any rule the kit never shipped** (not in the current additions and not in
    `.retired[]`) is the **user's own** → **always keep it**, untouched.
  - Show the user the per-rule diff (what will be adopted, what will be retired)
    and let them override individually; the default is to adopt this version's set.
    Apply the choices, then produce the final unioned document.
- **Dangerous modes are the user's call**: if the migrated settings enable
  `permissions.defaultMode: bypassPermissions` or the skip-prompt flags
  (`skipDangerousModePermissionPrompt`, `skipAutoPermissionPrompt`), do NOT
  strip them. Tell the user these are on (Claude runs without permission
  prompts by default) and offer to turn them off — keep their setting unless
  they say so. This kit's own template never adds these.
- **Session history (opt-in):** ask the user whether to also migrate their
  session history — `history.jsonl`, `projects/`, `sessions/`, and `todos/`/`tasks/`
  (past conversations, input history, todo state). **Off by default**; copy these
  (merging into any existing dirs) only if they say yes. Even then, NEVER copy the
  secret-prone state: `.credentials.json`, `shell-snapshots/`, `session-env/`,
  `paste-cache/`, `file-history/`, `telemetry/` — those can capture exported tokens
  or pasted/edited secrets.
- If a config-driven hook (web-egress / harness-pointer) is enabled, copy
  `shared/aka-claude-tools.config.example` → `<dir>/aka-claude-tools.config`.
- **Web egress sanitizer (if selected):** register it TWICE in
  `hooks.PreToolUse` — once with matcher `WebSearch|WebFetch` and once with
  matcher `Bash` (the script self-gates: Bash commands without an outbound tool
  exit immediately).
- **command-guard (if selected):** requires `bun` — skip it (and say so) if
  `bun` isn't installed. Register the hook command as
  `<absolute path to bun> <dir>/hooks/command-guard.ts` — hook subshells may
  not have `bun` on PATH, so a bare shebang can silently fail to launch.
- **RTK rewriting (if selected):** also merge `config/rtk-allowlist.json` into
  the profile's `permissions.allow` (union, never replace). It contains only
  strictly read-only `rtk` forms; do NOT widen it to `Bash(rtk:*)` — rtk fronts
  curl/aws/psql/docker, so a blanket prefix is effectively a general Bash allow.
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
- **Alias**: add it to the user's shell rc inside an idempotent managed block:
  ```
  # >>> aka-claude-tools managed: <alias> >>>
  alias <alias>='CLAUDE_CONFIG_DIR="<dir>" claude'
  # <<< aka-claude-tools managed: <alias> <<<
  ```
  Replace the block if one with the same alias already exists.

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
