# tests/

The flow test suite. Fully sandboxed — every test runs against a fake `$HOME`,
throwaway git clones, and temp dirs; **no real `~/.claude*` profile or the real
repo working tree is ever touched.** Deps: `bash`, `jq`, `git` (the project's own),
plus `bun` for the `command-guard` paths (skipped with a note when absent).

```bash
tests/run.sh              # all tests
tests/run.sh guards       # only files matching *guards*
```

CI runs the suite on every PR (`.github/workflows/tests.yml`, with `bun` installed
so the `.ts` guard deploy is exercised) alongside the shell/json lint
(`.github/workflows/ci.yml`).

## What each file covers

| File | Covers |
| --- | --- |
| `test_install` | Forward `--defaults` install: profile created, every recommended addition deployed with the path remap, no `$comment` leak. |
| `test_idempotency` | A re-run converges: settings.json canonical-identical (`jq -S`), a single managed alias block, no duplicate hook registrations. |
| `test_settings_merge` | A layer-in-place install over a profile with the user's OWN denies/allows/hooks unions them in (never drops them), adopts kit rules, strips `$comment`. |
| `test_helpers` | Unit tests of install.sh's pure helpers — sourced via the source-guard, in a subshell: `merge_settings`, `prune_hook_regs`, `prune_statusline`, and the rebuild rollback handler. |
| `test_uninstall` | Deselecting an addition removes its files AND prunes its settings registrations; still-selected additions and the user's own settings stay. |
| `test_select` | `CT_ADDITIONS` selection lever: exact-subset deploy, a non-recommended addition + its config template, empty = none, an unknown id aborts loudly. |
| `test_reconcile` | A retired kit permission rule is dropped on upgrade; a rule the kit never shipped (the user's own) is kept. |
| `test_retired_cleanup` | An addition the kit dropped (tombstoned in `managed-permissions.json.retiredAdditions`) has its orphan files removed on upgrade; user-owned files untouched. |
| `test_guard_registration` | Egress guards wired correctly: leak-guard registered under both `WebSearch\|WebFetch` and `Bash`; command-guard via an absolute `bun` path; shared `hooks/lib` placed. |
| `test_manifest` | `additions.json` integrity: valid, unique ids, declared files exist, no undeclared orphans (shared `lib/` excepted). |
| `test_promote` | Reverse flow (`tools/promote.sh`): a live edit round-trips path-remapped; a planted personal trace is refused; `--list` resolves the manifest. |
| `test_guards` | The shared adversarial corpus (`corpus.json`) against BOTH egress guards: every block case blocked by ≥1 guard, every allow case passes both; plus fail-closed when the patterns file is missing. |
| `test_tools` | Pre-publish leak gates: `leak-lib.sh` pattern library, `audit-history.sh` failing on secrets in file history / commit messages, `graduate.sh` arg validation. |

## Harness (`lib.sh`)

Source it at the top of a test; it provides `sandbox` (a temp dir auto-removed on
exit — rooted under one per-process dir so it survives `d="$(sandbox)"`), and asserts:
`assert_ok` / `assert_fail` (exit-code), `assert_file`, `assert_eq`, `assert_grep` /
`assert_ngrep` (regex), and `assert_lit` / `assert_nlit` (**literal** substring — use
these for filesystem paths, hook commands, and JSON fragments that contain regex
metacharacters). End every test with `t_summary`.

### Gotchas worth knowing
- The installer's prompts read from **`/dev/tty`**, not stdin — you cannot drive the
  interactive menu by piping answers. Non-interactive runs use `--defaults`
  (`CT_NONINTERACTIVE=1`, recommended set) and `CT_ADDITIONS="id ..."` to pick an
  exact subset. install.sh is source-guarded, so a test can `source` it inside a
  subshell to unit-test the pure helpers without running an install.
- Secret SHAPES in `corpus.json` and `test_tools` are deliberately fake; `test_tools`
  assembles them from fragments at runtime so this directory carries no token a
  history audit would flag.
