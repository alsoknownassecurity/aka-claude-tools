---
name: loop-designer
description: "Compiles a finished spec/plan into a MINIMAL kickoff prompt that points a fresh orchestrator session at the spec and lets it run — clear goal, hard guardrails, and a lot of room to decide tactics and react to reality. Works with any structured plan that has verifiable acceptance criteria, constraints, and human approval gates (PLAN.md, SPEC.md, a PRD with checkboxes). Design philosophy: a capable frontier-model orchestrator derives most operational discipline (commit staging, worktree integration, baselines, serialization) from reality on its own — so the emitted prompt stays small and only states what a capable orchestrator would get WRONG without being told (verify-yourself, context hygiene, don't self-sign approval gates). Two workflows: Compile (generate a minimal kickoff prompt from a spec) and Harden (audit + slim an existing hand-written kickoff prompt). USE WHEN: compile a spec/plan into a run, design the loop, kickoff prompt, orchestrator prompt, execution prompt, run this plan autonomously, execute the spec end to end, turn the plan into a session, hand this spec to a new session, harden my kickoff prompt. NOT FOR authoring the spec itself, or interval-based re-runs of an arbitrary command."
---

## Purpose

You just finished a spec. **loop-designer turns it into the smallest prompt that runs it well.**
The orchestrator is a capable frontier model — given a clear goal and hard guardrails, it
figures out tactics, delegation, and recovery from reality on its own. So the emitted prompt
carries the *discipline*, not a procedure: goal, constraints, the few rules a smart orchestrator
would otherwise get wrong — and explicit permission to decide everything else.

A usable spec has: checkable acceptance criteria (ideally with a probe per criterion — how to
verify it), hard constraints / "Anti:" criteria (things that must NEVER appear), and explicit
human approval gates.

## When to use
- Right after a spec/plan reaches a usable state and you want to execute it autonomously in a
  fresh session.
- When someone hands you a hand-written orchestrator prompt to improve (→ Harden).

## When NOT to use
- To write or audit the spec itself. Trivial task → just do it. Interval polling → a loop runner.

---

## Architecture — two tiers (this is the refinable surface)

> **Design principle (the Bitter Lesson, applied to prompts).** Default to OMITTING. Every line
> in the kickoff prompt competes for the orchestrator's attention; the more you spell out, the
> less room it has to react. Mark a thing MUST-HAVE only if a capable orchestrator would get it
> WRONG without being told. If it reliably derives it from reality — as validated runs did for
> commit staging, worktree integration, baselines, and serialization — it is NICE-TO-HAVE at
> most, included only when this spec's characteristics warrant it. **Bias hard toward minimal.**

> **Evidence base.** Grounded in three multi-hour validated runs (a web-prototype feature drive
> taking a spec from 17/60 to 60/60 criteria; a provenance-typed iOS UI rebuild, 0 → 50/139; an
> iOS feature-gap audit, 20/131 across 32 loop iterations). The consistent lesson: the
> orchestrator SUPPLIED the operational discipline unprompted; the rules that earned their keep
> by being stated were verify-yourself and context hygiene; the only thing that cost a turn was
> a self-contradictory GOAL. The verify rules are load-bearing — everything else is optional.
> Multi-agent runs added the handful of guardrails a smart orchestrator genuinely *did* get
> wrong without being told — distilled in **`FieldLessons.md`**; Compile Step 3 consults it.

### Tier 1 — MUST-HAVE CORE (always emitted, ~7 lines, each terse)

The irreducible discipline a smart orchestrator still needs stated. Keep each to one line.

- **M1 · Goal + loop** — drive the spec's open criteria to verified-done (or explicit
  blocked/deferred); loop until only human gates remain.
- **M2 · Spec is the source of truth** — `{{SPEC_PATH}}` in `{{REPO}}`; derive every specific
  from it; treat its constraints and "Anti:" criteria as non-negotiable. This prompt is only
  discipline.
- **M3 · Verify it yourself (the scar)** — mark nothing done you haven't verified against its
  probe yourself; for anything user-facing, **render the frame — don't trust a grep, a symbol, a
  subagent's word, or a green test count.** Close visual/honesty criteria on a DIFFERENTIAL
  render (the same surface under ≥2 fixtures); a value that doesn't move across fixtures is the
  tell a single screenshot and a passing test suite both hide. This is the load-bearing rule;
  dropping it recreates the disease.
- **M4 · Context hygiene** — keep YOUR context lean: delegate the reading and the coding, require
  terse conclusions, never pull whole files into your own context.
- **M5 · Don't self-sign human gates** — your launch is not approval{{APPROVAL_CLAUSE}}; surface
  blocking gates and stop for the human; sign nothing on their behalf.
- **M6 · Land + resume** — commit + push each verified batch; leave the spec accurate enough to
  resume cold.
- **M7 · You decide the rest** — sequencing, what to delegate and to whom, when to parallelize,
  tactics, tooling — your call; adapt as you learn what's actually true.

### Tier 2 — NICE-TO-HAVE CATALOG (include only when the trigger fires; keep each terse)

Most of these are operational discipline the orchestrator will likely supply on its own. Add a
block only when this spec makes the cost of getting it wrong high enough to be worth a line.
`{trigger, text}`.

- **N1 · Self-contained slices** — *trigger:* large/multi-feature spec. *text:* "Per work-unit,
  hand the subagent a self-contained slice {paths + criteria + constraints + probe + terse
  return format}; reconcile it back to the spec."
- **N2 · Worktree integration** — *trigger:* subagents that isolate into worktrees off a shared
  tree. *text:* "Producers may self-isolate into worktrees and return truncated; pull each diff
  into the integration tree and re-run probes THERE — a worktree-only result doesn't count."
- **N3 · Shared-file ordering** — *trigger:* ≥2 units that write the same files (routes, index,
  tokens, schema). *text:* "Serialize units that write SEMANTIC shared state (shared types,
  tokens, schema); ADDITIVE registrations to a shared file (a new `switch`/route/tab case) can
  run in parallel and be hand-merged — don't serialize a whole file just because each unit
  appends one entry."
- **N4 · Commit hygiene** — *trigger:* repo tree carries unrelated changes, or strict-scope
  spec. *text:* "Stage explicit paths (never `git add -A`); gate each commit's diff against the
  allowed scope; confirm no `[ahead N]` after push."
- **N5 · Green baseline** — *trigger:* compiled stack where breakage is hard to attribute.
  *text:* "Establish a green baseline (typecheck/build/test) before dispatching; if already
  broken, stop."
- **N6 · False-clean vigilance** — *trigger:* grep/symbol-probe-heavy spec, OR a
  build/test/render harness on an unfamiliar stack. *text:* "Re-run a probe that looks too clean
  (bad globs, masked exit codes, regex over-matching). Prove the HARNESS before trusting the
  first green: a test runner can print SUCCESS with 0 tests executed (e.g. Swift Testing emits
  the legacy `Executed 0 tests … TEST SUCCEEDED` line alongside the real result — bind to a
  count > 0 with no failures); and a render-verify can screenshot a STALE binary from the wrong
  build dir (multiple DerivedData/build dirs — install from the path the build system reports,
  not `find | head`)."
- **N7 · Delegated visual sweep** — *trigger:* visual/render/theme criteria. *text:* "Delegate
  bulk render verification to a subagent that returns a PASS/FAIL matrix; don't pull screenshots
  into your context; render the scar-class frames yourself."
- **N8 · Adversarial verify** — *trigger:* high-stakes or correctness/security-critical
  anti-criteria. *text:* "For high-risk confirmed criteria, have a second independent subagent
  try to REFUTE before checking the box."
- **N9 · Checkpoint emphasis** — *trigger:* very long run with many criteria. *text:* "Each
  batch is a checkpoint: commit/push/update progress so the loop survives a mid-run death."
- **N10 · Budget/scale** — *trigger:* user set a token target. *text:* "Treat the target as a
  hard ceiling; scale fan-out to remaining budget; log anything dropped."
- **N11 · Observer** — *trigger:* unattended AND high blast radius. *text:* "Spin a read-only
  observer subagent to vote continue/halt against the activity log; halt on a halt vote."
- **N12 · Autonomous approval** — *trigger:* user sets APPROVAL=YES. *text:* "Launching counts
  as approval of blocking gates; record it and don't stop mid-loop."
- **N13 · Re-inspect producers for the spec's own anti-pattern** — *trigger:* spec with a
  doctrinal `Anti:` criterion (a forbidden construct/pattern, not just a value). *text:*
  "Producers reintroduce the exact pattern the spec forbids while self-reporting it absent —
  name the forbidden construct in each producer's spec AND re-grep/read their returned diff for
  it yourself before integrating; never trust the producer's 'no <X>, confirmed'." *(Validated
  repeatedly: in one run four separate producers reintroduced a banned scalar-sentinel pattern,
  each reporting clean; only the orchestrator's own re-inspection caught them. Corollary: land
  one full reference unit first, then point later producers at it — pattern-by-example prevents
  relapses that a prose ban alone does not.)*
- **N14 · Non-interactive (hands-off autonomy)** — *trigger:* a loop meant to run
  unattended/hands-off. *text:* "Never run a command the harness gates for approval — it stalls
  the loop waiting for a human. No `rm`/destructive ops (overwrite files in place or use a fresh
  `mktemp -d`, never `rm -f`); no interactive prompts (pass `--yes`/non-interactive flags)."
  *(Validated: a hands-off loop kept stalling because it `rm -f`'d screenshot dirs before each
  render batch — yet the screenshot tool already overwrote in place. Prefer overwrite; the fix
  is removing the destructive command, NOT allowlisting `rm`.)*
- **N15 · Clean build before closing 0-warnings** — *trigger:* any criterion that includes "0
  warnings" / "build clean"; any compiled stack where warnings are a quality gate. *text:* "Run
  a CLEAN build (not incremental) before closing any 0-warnings criterion — incremental builds
  reuse cached object files and do NOT recompile already-committed files, so 'no warnings' from
  an incremental build is unreliable." *(Validated: an incremental build hid 3 real warnings in
  a committed file.)*
- **N16 · Stall watchdog + lean agents** — *trigger:* multi-agent fan-out (≥2 coding agents) OR
  any unattended/overnight run. *text:* "Arm a watchdog on any multi-agent or unattended run: an
  agent whose output-file mtime goes static for many minutes while the tree shows partial work
  is stalled — stop it and assess (the partial is usually ~99% done; finish the blocker, don't
  reset). Use lean general-purpose subagents at an appropriate model tier, not heavy persona
  agents — the latter crash under load; the watchdog catches hangs, lean agents prevent
  crashes."
- **N17 · Spec changelog as running lesson ledger** — *trigger:* multi-session run, OR any run
  where a context-limit break mid-session is anticipated. *text:* "Append each incident's
  learning — premise corrections, producer failure causes, caveats, unexpected finds — to the
  spec's `## Changelog` AS YOU GO; a cold-resume session reads the changelog first, not your
  context window."

> Add your own `{trigger, text}` blocks as you learn what a class of spec needs. When in doubt,
> leave it out — a capable orchestrator probably has it covered.

---

## Procedure — two modes

- **Compile** (generate from a spec) → **`Workflows/Compile.md`**: fill the M-core from the
  spec, add only the N-blocks this spec needs, confirm the `{{APPROVAL}}` knob, emit a MINIMAL
  prompt + a one-line build-sheet, and persist it to one canonical
  `<repo-root>/EXECUTION-PROMPT.md` — overwritten every compile, stamped with the source spec
  path + a STALE-IF rule so a clean session never runs an outdated loop.
- **Harden** (slim an existing prompt) → **`Workflows/Harden.md`**: map a hand-written prompt
  onto the tiers, CUT what a smart orchestrator already does, keep the core + the few earned
  guardrails.

The deliverable is the emitted prompt — biased toward small — AND its canonical
`EXECUTION-PROMPT.md` (overwritten + provenance-stamped each compile, never hand-edited). Do NOT
execute the spec from this skill.
