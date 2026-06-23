# Changelog

All notable changes to **aka-claude-tools** are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Pre-1.0: minor versions may carry breaking changes; they are called out below.

## [0.2.0] — public-ready prep

First public-ready release: the kit is scrubbed of internal traces, the docs are
rewritten for a public audience, and the legacy upgrade path is dropped.

### Added
- `install.sh --version` (and `-V`) prints the kit version from the new top-level
  `VERSION` file. Runs before any dependency check, so it works on a bare checkout.
- This `CHANGELOG.md`.

### Changed
- Lean README rewrite for public release — benefit-led, grouped by what each piece
  does, with the deeper mechanics linked out rather than inlined (#74).

### Removed
- Legacy pre-marker hook migration. The public kit has no pre-rename installs, so the
  one-time migration shim and its helpers are gone (#73). **Breaking** only for a
  profile first installed before the hook-rename marker existed (not applicable to
  any public install).

### Fixed
- command-guard no longer treats a `case` statement's pattern-list alternations
  (`case "$ext" in py|sh|bash|zsh)`) as a pipe-to-shell — a false positive — while
  still blocking real pipes to a shell near or inside a `case` (#75, #77).

### Security / hygiene
- Test fixtures genericized: removed a real fleet host and a `myframework/` path from the
  fixtures (#76), and scrubbed the last environment hints — the planted-leak fixture
  now uses a synthetic RFC1918 address and the auth-inherit fixture a neutral terminal
  name (#78). The only remaining external-project reference is the README acknowledgment.
- `setup_alias` (the sole shell-rc writer) now rejects an alias name or config dir that
  can't be safely embedded in the launcher block instead of writing it verbatim. An
  unsafe name (a shell metacharacter or leading `-`) or dir (a quote, `$`, backtick,
  backslash, or control character) could otherwise break out of the
  `alias NAME='CLAUDE_CONFIG_DIR="DIR" claude'` quoting and inject code — at rc-source
  time or, because the `"DIR"` is reparsed inside live double quotes when the alias is
  invoked, at alias-expansion time (`$()` / backtick / `${}`). It now fails closed with
  a clear message at every write path. The accepted alias-name charset also excludes `.`
  so an accepted name carries no regex metacharacter for the collision/enumerate greps (#90).

## [0.1.1] — pre-public-prep checkpoint

Hot-path hooks ported from bash to TypeScript (bun), behavior-preserving. Marks the
state before the v0.2.0 public-ready prep.

### Changed
- `rtk-safe.sh` → `rtk-safe.ts` (#70) — ~2.8× faster, byte-identical rewrites.
- command-guard egress-alert table restructured (#71) — deny semantics unchanged.
- `leak-guard.sh` → `leak-guard.ts` (#72) — verified against the prior bash version
  with 196-case differential parity.

### Removed
- The bun-less soft-skip hedge in leak-guard. **Breaking:** leak-guard now requires
  bun (already a hard dependency of command-guard).

## [0.1.0] — initial internal deployment

Initial internal deployment of the isolated-profile installer, the secure-defaults
base, and the guard hooks.

[Unreleased]: https://github.com/alsoknownassecurity/aka-claude-tools/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/alsoknownassecurity/aka-claude-tools/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/alsoknownassecurity/aka-claude-tools/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/alsoknownassecurity/aka-claude-tools/releases/tag/v0.1.0
