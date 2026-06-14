---
name: shell-audit
description: Audit the shell startup chain (the rc file + every file it sources) for hardcoded credentials, persistence-suspicious patterns, duplicate or dangling aliases, and git-baseline drift. USE WHEN the user wants to review, secure, clean up, or maintain their shell aliases or startup files; check ~/.zshrc / ~/.bashrc for leaked secrets or persistence; or asks to "audit my shell config". Read-only detective tripwire — not a security boundary, and shell-startup only (not launchd/cron/ssh).
---

# shell-audit

Run the bundled read-only auditor and present its findings clearly and honestly.

## Run it

```
bash "$CLAUDE_CONFIG_DIR/skills/shell-audit/audit.sh" [rc-file]
```

No argument → it picks the rc from `$SHELL`. It walks that rc and every file
reachable through its `source` / `.` chain (cycle-safe via a visited-set) and
prints four sections: **credentials**, **persistence patterns**, **alias
hygiene**, **git drift**.

## Present the results

- **Credentials first (highest severity).** NEVER print secret values — the
  script redacts them; keep them redacted. Recommend moving any secret out of
  startup files into a keychain / credential helper, and **rotating** anything
  that was exposed (these files are often git-tracked and world-readable to the
  user).
- **Persistence patterns = "eyeball these".** Most are legit (setup scripts);
  for each, confirm it fetches/execs only what's intended and that nothing writes
  into another rc.
- **Alias hygiene** — offer to dedupe (decide which definition wins) and note any
  launcher alias whose target dir is missing.
- **Git drift** — confirm each change is the user's. A modified-vs-HEAD or
  untracked startup file is the strongest tamper signal available here.
- **State the scope limit** every time: this covers the *shell-startup slice
  only* — not launchd/LaunchAgents, cron, login items, ssh authorized_keys/config,
  or git hooks. Don't present it as comprehensive persistence detection.

## Don't

- Don't modify any startup file as part of the audit — it's read-only. If the
  user wants fixes, **propose** them and let the user apply: their dotfiles are
  Edit/Write-denied by design, so hand edits over via a `! <cmd>` prompt.
