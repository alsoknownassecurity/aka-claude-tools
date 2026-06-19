# Contributing to aka-claude-tools

Thanks for helping improve aka-claude-tools. This file covers the GitHub
mechanics; the substance of *how to make a good change* lives in
[`AGENTS.md`](AGENTS.md) — please read it first. It is the contributor guide for
humans and coding agents alike, and this file does not repeat it.

## Ground rules (from AGENTS.md)

- **Branch + PR, never push to `main`.** One focused change per branch
  (`feat/…`, `fix/…`, `docs/…`, `chore/…`) → one PR. Even the maintainer self-PRs.
- **Conventional commits:** lowercase imperative with a `feat:` / `fix:` /
  `docs:` / `chore:` / `refactor:` prefix.
- **Installer and hook changes are review-gated** — they write to users' config
  dirs and the hooks are security boundaries. Don't self-merge; state the blast
  radius in the PR body.

## Making a change

1. **Fork** and create a branch off `main`.
2. **Make one focused change.** Don't bundle unrelated edits — split them into
   separate branches/PRs.
3. **Verify before you push** (CI enforces the same checks):
   - `bash -n install.sh shared/lib/common.sh` — syntax-clean under **bash, not
     zsh** (`for x in $var` word-splits differently in bash, which can silently
     fool a hand test run from zsh).
   - Exercise changed paths in a **sandbox config dir** (`mktemp -d`), never the
     live `~/.claude*`. Prove the behavior (files placed/removed, settings
     merged/pruned) rather than asserting it.
   - `jq empty config/*.json` — the config still parses.
   - Stay cross-platform: macOS ships **BSD** tools, Linux **GNU** — avoid
     GNU-only flags. `jq` is the one hard dependency.
4. **Open a PR** using the template. Fill in *What & why*, *Blast radius*, and the
   *Verification* checklist.
5. **Delete the branch after merge.**

## Adding or changing an "addition"

The addition menu and each addition's build/uninstall logic are driven entirely by
[`config/additions.json`](config/additions.json) — the single source of truth
shared by the interactive installer (`install.sh`) and the agent path
([`agent-install.md`](agent-install.md)). Change it there; never hardcode an
addition into one path and not the other. Maintainer notes go in `"$comment"`
keys, which are stripped from the user's merged `settings.json` — never ship them
to a user.

## Reporting bugs and security issues

- **Bugs / features:** open an issue using the templates.
- **Security vulnerabilities:** do **not** open a public issue — follow
  [`SECURITY.md`](SECURITY.md) (private GitHub advisory, or email
  will@akasecurity.io).

## License

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE) that covers this project.
