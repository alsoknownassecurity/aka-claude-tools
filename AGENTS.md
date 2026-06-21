# AGENTS.md — aka-claude-tools

Cross-harness contributor guide for this repo (Claude Code, Codex, Gemini, Cursor,
and humans). `CLAUDE.md` and `GEMINI.md` just import this file.

aka-claude-tools is a **distributable product**: a shell installer that layers
isolated Claude Code config profiles — secure defaults and guard hooks — onto a
user's machine. It is **GitHub-hosted and PR-gated**. Treat it like the
security-focused upstreams it cross-references (e.g. `trailofbits/claude-code-config`),
not like an internal self-hosted repo.

## Change workflow — branch + PR, never push to `main`

This **overrides** any workspace/global default that allows direct pushes to
self-hosted repos. Here `main` is protected by convention:

- **One focused change per branch → one PR.** Branch off `main`
  (`feat/…`, `fix/…`, `docs/…`, `chore/…`). Keep PRs small and independently
  reviewable — split unrelated changes into separate branches.
- **Do not commit or push to `main`.** Even the maintainer opens PRs for their
  own work — that is exactly what the upstream ToB config does (the owner
  self-PRs rather than pushing to main).
- **Conventional commits**: lowercase imperative with a `feat:` / `fix:` /
  `docs:` / `chore:` / `refactor:` prefix.
- **Delete the branch after merge.**
- **Installer and hook changes are review-gated.** The installer writes to users'
  config dirs and the hooks are security boundaries — do **not** self-merge such
  changes without a second review. State the blast radius in the PR body.

## Before you open a PR

- `tests/run.sh` — the flow suite (sandboxed: fake `$HOME`, throwaway clones,
  never touches a real profile). It checks `install.sh` deploys with the path
  remap, `additions.json` manifest integrity (no missing/orphan files), and the
  `tools/promote.sh` reverse round-trip + leak guard. CI runs it on every PR.
- `bash -n install.sh shared/lib/common.sh` — syntax-clean. The installer runs
  under `#!/usr/bin/env bash`; **verify under bash, not zsh** (`for x in $var`
  word-splits in bash but not zsh, which will silently fool a hand test).
- **Exercise changed paths in a sandbox** — a `mktemp -d` config dir, never the
  live `~/.claude*`. Prove the behavior (files placed/removed, settings merged/
  pruned) rather than asserting it.
- Stay cross-platform: macOS ships **BSD** tools, Linux **GNU** — avoid GNU-only
  flags. `jq` is the one hard dependency.

## Repo conventions

- The addition menu and per-addition build/uninstall logic are driven **entirely
  by `config/additions.json`** — the single source of truth shared by Path B
  (`install.sh`) and Path A (`agent-install.md`). Add or change an addition there;
  never hardcode it into one path and not the other.
- Maintainer-only notes live in `"$comment"` keys inside the JSON payloads and are
  stripped from the user's merged `settings.json` — never ship them to a user.
- Don't modify working, unrelated code to suit a style preference.
