# tools/ — maintainer flow scripts

Maintainer-only helpers for moving work between the live profile, this repo, and
the public upstream. **Not shipped to users** (install.sh deploys `config/` only)
and not part of a public release — they live here so the whole team can run,
review, and test them.

## The pipeline

```
  ~/.claude-aka            this repo (private dev)         public upstream
  (live profile)   ──┐     aka-claude-tools-dev      ┌──   aka-claude-tools
  author + test      │     branch + PR + review      │     append-only, all PRs
                     ▼                                ▼
              promote.sh  ───────────────────▶  graduate.sh ───▶ public PR
```

- **`promote.sh`** — carry a live profile edit back into the repo. Manifest-driven
  (reads `config/additions.json`), path-remapped (`profile/<X>` → `config/<X>`),
  and leak-scanned (refuses to stage your name/email/host/home-path). Won't stage
  onto `main`.
  ```bash
  tools/promote.sh --list                     # addition ids
  tools/promote.sh --branch feat/x conductor  # stage conductor onto a branch
  tools/promote.sh --kind skill newthing       # a NEW artifact (then add to additions.json)
  ```
- **`graduate.sh`** — replay private dev commits onto a fresh branch off the
  public upstream (cherry-pick by content; never force-pushes public), guarded for
  identity + leaks. For embargoed work that was developed privately.
  ```bash
  tools/graduate.sh --branch fix/cve <dev-commit>...
  ```

- **`audit-history.sh`** — pre-seed gate. Scans an entire git history (every blob
  at every commit + commit messages) for secrets and operator-specific identifiers
  before it's published. Run it on the public seed right before pushing.
  ```bash
  tools/audit-history.sh --repo ../aka-claude-tools-public --ref main
  ```

Both default the repo to the clone they live in and are fully overridable by env
(`AKA_REPO`, `CLAUDE_CONFIG_DIR`, `AKA_PUBLIC`, `AKA_DEV`).

**Leak patterns.** The committed patterns ([`leak-lib.sh`](leak-lib.sh)) are generic
and name no specific person/host/namespace. Your own identifiers (name, tailnet,
private namespaces) stay out of the repo — put them in a gitignored
`tools/leak-patterns.local` (see `leak-patterns.local.example`) or `$AKA_LEAK_EXTRA`.
promote / graduate / audit-history all pick them up.

## Tests

`tests/run.sh` exercises this flow end-to-end in sandboxes (fake `$HOME`, throwaway
clones — never touches a real profile). Run it before opening a PR; CI runs it too.
