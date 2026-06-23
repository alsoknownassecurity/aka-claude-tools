# Public-export runbook (example / template)

How this private dev repo is turned into the **public** upstream as a **one-time
seed that preserves filtered git history** — every commit kept, every operator
identifier and every must-not-ship blob scrubbed out of *all* of history first.

> **This file is a sanitized example.** It documents the *process* with
> **placeholders** only — no real names, emails, hosts, or third-party lineage
> details. The real substitution values live OUTSIDE the repo:
> - operator identifiers → gitignored [`tools/leak-patterns.local`](leak-patterns.local.example)
>   (already the mechanism `promote.sh` / `graduate.sh` / `audit-history.sh` read), and
> - the full filter spec (exact maps, file lists, mailmap) → a **private maintainer
>   release note**, never a tracked file.
>
> Keep it that way: if you fill this in, fill in the *private* copy, not this one.
> If you'd rather this example never reach the public repo at all, add it to the
> path-removal list in step 4 so the filter drops it from history too.

This is for the **initial seed only**. Ongoing public contributions after the seed
use the append-only flow in [`README.md`](README.md) (`graduate.sh` → public PR),
never another history rewrite.

---

## Why filtered history (not a fresh squash)

The default promotion doctrine is a *fresh export with no history* (current tree as
a single initial commit). This repo deliberately chose the alternative: **keep the
full commit history, filtered**, because the development history has value and the
scrub can be proven complete. The trade is that the scrub must be airtight across
*every historical blob and message*, not just the current tree — which is what
`audit-history.sh` gates.

**Maximize retained commits.** The scrub rewrites content/messages/authorship *in
place* and never needs to drop a commit, so commit count is independent of it. The
only thing that drops commits is `git-filter-repo`'s own pruning — so disable it:

```
--prune-empty=never --prune-degenerate=never
```

This keeps every merge commit, and keeps any commit that becomes empty after a
must-not-ship file is removed (as an empty marker commit) rather than pruning it.
The only unavoidable cost is that a commit whose *entire* content was a removed file
becomes contentless — kept as an empty marker, per the max-commits choice.

---

## Prerequisites

- [`git-filter-repo`](https://github.com/newren/git-filter-repo) installed
  (`pipx install git-filter-repo` or your package manager). The repo's history is
  rewritten with this, never `filter-branch`.
- `tools/leak-patterns.local` populated with your **real** operator identifiers
  (gitignored — see `leak-patterns.local.example`). `audit-history.sh` reads it as
  its FAIL set, so the gate actually checks for *your* identifiers, not just generic
  secret shapes.
- The **private release note** open, holding the real values for every placeholder
  table below.
- All public-prep content merged to `main` and tagged (this repo seeds from the
  tagged release commit).

---

## The scrub spec (placeholders — real values in the private note)

Build three inputs for `git-filter-repo`. **Every left-hand value below is a
placeholder**; substitute the real ones from the private note.

### 1. Text + message replacements — `replace.txt`

Passed to BOTH `--replace-text replace.txt` AND `--replace-message replace.txt`
(replace-text alone misses commit *messages*; you need both). One `find==>replace`
per line; `regex:` prefix for patterns.

```
OPERATOR_EMAIL==>PUBLIC_EMAIL
OPERATOR_USER@OPERATOR_HOST==>generic-user@example
OPERATOR_HOSTNAME==>example-host
OPERATOR_PRIVATE_NET==>example-net
OPERATOR_PERSONAL_EMAIL==>PUBLIC_EMAIL
OPERATOR_USERNAME==>generic-user
OPERATOR FULL NAME==>Public Name
regex:\bOPERATOR_HOST_PREFIX-==>HOST-
/Users/OPERATOR_USERNAME==>/Users/me
/home/OPERATOR_USERNAME==>/home/me
```

### 2. Identity rewrite — `mailmap`

Passed to `--mailmap mailmap`. Rewrites author/committer identity across all
commits (the text replacements above do NOT touch the identity fields).

```
Public Name <PUBLIC_EMAIL>  OPERATOR FULL NAME <OPERATOR_EMAIL>
<PUBLIC_EMAIL>              HANDLE <OPERATOR_PERSONAL_EMAIL>
Contributor <CONTRIB_PUBLIC_EMAIL>  Contributor <CONTRIB_OLD_BRAND_EMAIL>
```

### 3. Must-not-ship paths + lineage phrasing

Some files cannot ship **even in history** (third-party-derived sources that may not
be redistributed, and any code whose mere presence reveals a lineage you are
removing). Remove them from all history:

```
git-filter-repo --invert-paths --path <PATH> [--path <PATH> ...]
```

and, in the same `replace.txt`, strip any **derivation/attribution phrasing** that
asserts that lineage in code comments or commit messages, plus any historical
file-name references to the removed files (map them to their current names).

> The **exact** path list, phrase maps, and name maps are lineage-revealing, so they
> live in the **private note**, not here. **Keep rule:** the intentional third-party
> *acknowledgment* in the README is preserved — write the removal rules narrowly so
> none of them match that acknowledgment line, and do NOT add a blanket scrub of the
> acknowledged project's name.

---

## Procedure

1. **Fresh throwaway clone of the tagged release** (never filter your working repo):
   ```bash
   git clone --no-local <DEV_REPO_URL> /tmp/aka-export && cd /tmp/aka-export
   git checkout <RELEASE_TAG>           # e.g. the latest vX.Y.Z
   ```
   Only `main`/the tag is seeded — stale branches do not travel.

2. **Run the filter** with the three spec inputs + the max-commits flags:
   ```bash
   git-filter-repo \
     --replace-text   replace.txt \
     --replace-message replace.txt \
     --mailmap        mailmap \
     --invert-paths --path <PATH> [--path ...] \
     --prune-empty=never --prune-degenerate=never
   ```

3. **HARD GATES — all must pass before the filtered history leaves your machine:**
   - **Leak scan (zero FAIL):** `tools/audit-history.sh --repo /tmp/aka-export --ref HEAD`
     — scans every blob at every commit + every commit message. Exit 0 required.
     (It FAILs on secret shapes + your `leak-patterns.local` identifiers; it WARNs on
     generic infra patterns — eyeball those, they also appear in intentional examples.)
   - **Suite green on the filtered HEAD:** `tests/run.sh` → all pass. (The fixtures
     are already filter-stable — they use synthetic values that no scrub rule matches.)
   - **Removed files are gone from ALL history:** `git log --all --oneline -- <PATH>`
     returns nothing for each removed path.
   - **Acknowledgment intact:** the README third-party acknowledgment still reads as
     intended (the scrub removed lineage *claims*, not the courtesy credit).
   - **Identities clean:** `git log --all --format='%an <%ae> | %cn <%ce>' | sort -u`
     shows only public identities.

4. **Seed the public repo PRIVATE first.** Create the public-named repo as **private**,
   push the filtered history, and review the *actual repo* (multiple passes). History
   fixes are cheap and complete only while private — re-run the filter and force-push,
   or delete + recreate.

5. **Flip private → public** — the point of no return, an explicit operator action.

---

## After it's public — remediation policy

Once public, a force-push does **not** remediate a leak (clones, forks, and the
forge's commit cache retain it). So:

- **Front-load** the leak scan into the private review (step 3) — that is the real gate.
- A sensitive value that slips out post-flip is handled by **rotation/revocation**,
  not history rewriting.
- Cosmetic issues found post-flip are fixed **forward** (a normal commit), never by
  rewriting public history.
