## What & why

<!-- One focused change. What does this PR do, and why? Link any issue. -->

## Blast radius

<!-- Does this touch the installer, hooks, or settings users run? What could it
break for an existing profile on upgrade? -->

## Verification

- [ ] `tests/run.sh` passes (the flow suite — also enforced in CI)
- [ ] `bash -n install.sh shared/lib/common.sh` passes
- [ ] Exercised the changed paths in a sandbox (`mktemp -d` config dir, not `~/.claude*`)
- [ ] If you added/changed an addition, `config/additions.json` is updated to match
- [ ] No unrelated changes bundled in
- [ ] Conventional commit title (`feat:` / `fix:` / `docs:` / `chore:`)

<!-- Installer/hook/settings changes are review-gated — please don't self-merge
without a second review. -->
