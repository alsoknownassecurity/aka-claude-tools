# loop-designer — Field Lessons

Durable, cross-project lessons from real spec → orchestrator → loop runs. The **Compile**
workflow grafts the relevant subset (marked ⮕ GRAFT) into the kickoff prompts it generates, so
future loops inherit these guardrails instead of relearning them mid-run. Distilled from three
multi-hour validated runs: a web-prototype feature drive (17/60 → 60/60 criteria), a
provenance-typed iOS UI rebuild (0 → 50/139), and an iOS feature-gap audit (20/131 across 32
loop iterations). Where runs diverged, the divergence is noted — graft what matches the run's
actual behavior, not a blanket rule.

## A. Verification discipline (the scar — already core; reinforced)

- **Render the scar-class frames YOURSELF.** Never close a visual criterion on a subagent's
  "looks right," a clean grep, or a present symbol. Read the rendered image; compare to the
  contract.
- ⮕ GRAFT **Clean build for warnings, never incremental.** Incremental builds reuse cached
  object files and do **not** recompile unchanged files — an agent's "0 warnings" from an
  incremental build hides warnings in already-committed files. One run's incremental build hid
  3 real warnings in a committed file.
- **"Unused result" warnings are often real bugs, not cosmetics.** One such warning was a
  *dropped view*: a builder-style SwiftUI component (a `@ViewBuilder slot:` init that also had
  an `onAction:` closure) received an UNLABELED trailing closure, which bound to the wrong
  parameter and silently rendered the slot empty. Investigate these warnings; don't silence
  them. ⮕ GRAFT when the stack has builder-closure components: *pass the builder/slot argument
  with its explicit label so an unlabeled trailing closure can't bind to the wrong overload.*
- ⮕ GRAFT **Re-inspect each producer's diff for the spec's OWN `Anti:` pattern — they relapse
  and report it absent.** On a spec whose central anti-criterion banned a scalar-sentinel
  pattern, **four separate producers reintroduced exactly that pattern** — each reporting "no
  sentinels, confirmed," *with the spec forbidding it and a clean reference implementation to
  copy*. The producer self-report on the anti-pattern is worthless; grep/read their diff for
  the forbidden construct YOURSELF before integrating. Corollary: land one full reference unit
  first, then point later producers at it — pattern-by-example prevents relapses that the prose
  ban alone did not.
- ⮕ GRAFT **Tests-green ≠ honest — the multi-fixture render catches what unit tests pass.** A
  surface shipped 47 green unit tests and still rendered a fabricated default as confident
  data; only rendering the same surface under ≥2 fixtures and diffing the values exposed it. A
  value that does NOT change across fixtures is the tell a single shot (and a green test suite)
  hides. Close visual/honesty criteria on the differential render, never on the test count.
- ⮕ GRAFT **Prove the harness before you trust the first green — stack-specific false-cleans
  certify fakes.** Two near-misses, both would have closed a criterion on a lie: (1) **Swift
  Testing** prints the legacy `Test Suite … Executed 0 tests … ** TEST SUCCEEDED **` XCTest
  counter alongside the real result — a grep keyed on "TEST SUCCEEDED" is a false-clean; bind
  to the real `Test run with N tests passed` line, N>0, no failures. (2) **Multiple
  DerivedData/build dirs** exist (case-variant working-dir paths, per-worktree hashes) —
  `find … .app | head -1` grabbed a STALE pre-change binary, so the first render-verifies
  screenshotted old UI. Install from the build dir the build system reports
  (`xcodebuild -showBuildSettings`), never `find | head`. General rule: the first render/test
  of a run is suspect until the harness itself is proven.
- ⮕ GRAFT **Simulator screenshots accumulate in context — downscale or OCR to text.** Full-size
  retina screenshots poison subsequent image reads even after downscaling the new one — old
  large images in context block ALL further image reads. Mitigation: (1) downscale EVERY
  screenshot before reading it (`sips -Z 1200 <path>`); (2) for text extraction, OCR instead of
  an image read (a ~15-line Swift `VNRecognizeTextRequest` reader on macOS). **OCR is the
  durable verification path** for runs with many screenshots — graft this for any spec with ≥5
  render-verify steps on a simulator.

## B. Subagent execution model (the biggest source of surprises)

- ⮕ GRAFT **Check whether worktree isolation ACTUALLY worked this run before choosing your
  parallelism model — two runs diverged here.** In one, isolated worktrees frequently failed to
  create (agents ran in the SHARED tree); in another, worktree isolation worked every time. The
  model is NOT fixed — verify it once early, then:
  - **If worktrees isolate:** producers are safe to fan out in PARALLEL on disjoint files. Pull
    each diff into the integration tree and re-probe THERE (a worktree-only green is
    false-green); export a patch (`git -C <wt> diff --cached`), `git apply` to the integration
    tree; hand-merge the rare shared-file hunk; remove each worktree after integrating.
  - **If worktrees DON'T isolate:** changes land in your working tree — run **ONE** coding
    agent at a time; overlapping-file units are SEQUENTIAL; parallel fan-out is unsafe.
  - Either way, instruct every agent: **NO `git` branch/checkout/commit** in a shared checkout,
    **NO `git add -A`** (one run had an agent switch the shared HEAD; another's untracked
    artifacts would have been swept by `add -A`).
- ⮕ GRAFT **Serialize SEMANTIC shared state; parallelize ADDITIVE shared registrations.** Two
  producers editing the *meaning* of a shared type (a core struct, the view-model layer,
  tokens) MUST serialize. But two producers each appending an ADDITIVE entry to a shared
  registry — a new `case` in a nav `switch`, a new tab gate — are safe to run in parallel and
  hand-merge in seconds (non-overlapping hunks).
- ⮕ GRAFT **Use lean general-purpose subagents at an appropriate model tier, not heavy persona
  agents.** A heavy persona/narration agent crashed mid-fix repeatedly; switching to a lean
  general-purpose agent stopped it. Match the model tier to task difficulty: a frontier tier
  for judgment-heavy code, a smaller tier for mechanical passes.
- ⮕ GRAFT **Agents stall silently — arm a watchdog.** One agent hung ~45 minutes with a static
  output file and no completion event. The harness completion notification covers only the
  happy path — **silence ≠ progress.** Liveness check: the agent's output-file mtime going
  static for many minutes while the tree shows partial work = a stall; stop it and assess.
- **A stalled/crashed agent usually left a ~99%-done partial.** Assess the tree (build → triage
  remaining errors) and finish the last blocker rather than resetting wholesale — but verify
  the partial is *coherent* first (e.g. no unintended deletions).

## C. Scope & spine discipline

- ⮕ GRAFT **Stage explicit in-scope paths only; never stage pre-existing out-of-scope dirt.**
  The tree may carry another session's uncommitted work outside your scope — it must NEVER be
  staged. Stage by explicit path, then VERIFY the staged set excludes everything out of scope
  before each commit. Re-fetch before every push; confirm `ahead=0` after.
- **A "preserve the spine" premise can be falsified by reality.** A directory the spec assumed
  was pure-UI held view-models and types the tests and services depended on — a clean delete
  would have broken both. When a wipe/scope premise breaks, **STOP and surface it to the
  human**; don't self-resolve a scope decision that revisits a *recorded human decision*.
- **Over-deletion recovery is additive + verbatim.** When a wipe over-deletes helpers the spine
  still needs, RESTORE them verbatim into a sensible location rather than re-deriving them —
  and let the *consuming tests passing* be your verbatim-correctness proof.

## D. Human-gate & decision discipline

- **Never self-sign the human gates.** The launch is not approval. Surface them with evidence
  and stop.
- **Distinguish "ask" from "default-and-flag."** Ask the human when a decision *revisits their
  recorded choice* and has real tradeoffs. Take the safe default — and flag it — when the
  conservative choice is obvious (e.g. *preserve* load-bearing infrastructure that has no
  replacement in the contract, rather than silently dropping it).
- ⮕ GRAFT **Tell agents to STOP-and-report at genuine business-logic forks.** An agent that
  halts rather than guessing at a behavior-changing decision is behaving correctly — instruct
  them to do so, and reserve those decisions for the orchestrator/human.

## E. Session continuity across context windows

- ⮕ GRAFT **The spec changelog is the lesson ledger.** Append each incident's learning as you
  go — premise corrections, caveats, decisions, the cause of any rework — so a fresh session
  inherits the full context, not just the criteria checkboxes.
- **Handoff protocol at a context limit:** land everything **committed + pushed** (committed
  survives the session boundary; uncommitted is fragile). Mark partially-verified work
  **explicitly** (a pending marker, not a closed `[x]`) and make the resume session's FIRST
  task to independently re-verify anything committed but not personally verified. Then write a
  **minimal resume prompt**: (1) the proven per-unit template, (2) these lessons, (3) the exact
  current state (HEAD SHA, verified vs pending), (4) the next action, (5) the unsigned human
  gates. The resume prompt is itself a loop-designer artifact — minimal, but it carries the
  lessons forward.

## How Compile applies this

When compiling a kickoff prompt, fold the ⮕ GRAFT items into the prompt's discipline section,
tailored to the run's stack and the spec's nature (a wipe-heavy spec needs C; a multi-surface
render spec needs A; any multi-agent spec needs B). Don't graft all of it blindly — graft what
*this* spec will actually hit, and keep the prompt minimal. Items NOT marked GRAFT are
orchestrator disciplines (they belong to whoever runs the loop, not the emitted prompt).
