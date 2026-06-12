# Harden — slim an existing kickoff prompt to the core

Use when the user has a hand-written orchestrator/kickoff prompt and wants it improved before
running it. The orchestrator is a capable frontier model — so the usual problem is NOT missing
rules; it's **over-specification** that steals room it needs to react. Harden mostly CUTS.

Two passes: cut what the orchestrator already does, then confirm the small core survives.

## Pass 1 — CUT (the main event)
For every line, apply the test: *would a capable orchestrator get this wrong without being
told?* If no → cut it or demote it to a NICE-TO-HAVE the user can opt back in.
- Procedural how-to it derives from reality (commit staging, worktree integration, baselines,
  serialization, parallel-vs-serial mechanics) → **cut to a NICE-TO-HAVE, or drop entirely.**
- Restated spec detail (surfaces, probes, scope already in the spec) → cut; point at the spec.
- Prescriptive tactics ("prefer parallel", "use tool X") → cut; that's the orchestrator's call,
  and a wrong default actively misleads (a validated run had to override exactly this).
- Anything that reads like a manual → cut. It needs the goal and the guardrails, not a runbook.

## Pass 2 — KEEP the must-have core (M1–M7)
Confirm these survive, terse — add only if absent:
- Goal + loop; spec-as-truth + non-negotiable constraints.
- **Verify-yourself / render-the-frame** (the scar — the one rule worth its weight).
- Context hygiene (delegate, terse returns, don't pull files into context).
- Don't self-sign gates; launch ≠ approval; stop at blocking gates.
- Commit/push + resumable.
- An explicit "you decide the rest" grant of latitude.
The single highest-value fix is usually **a clean, non-contradictory GOAL** — a validated run's
only real stumble was a prompt that said "drive everything to done" while a blocking gate sat in
front of everything. Fix the goal; you rarely need to add a rule.

## Pass 3 — Harvest better framings (as CANDIDATES, not wins)
A good idea in an UN-RUN prompt is a hypothesis. If the prompt frames something better, backport
it into SKILL.md marked as a TEMPLATE; only validated runs promote it to proven. Never present a
harvested candidate as battle-tested.

## Output
- A short ledger: what you CUT (and why the orchestrator covers it), what you KEPT.
- The slimmed prompt in one copy-paste block — smaller than the input, with more room to react.
- Any skill backports you made, flagged as templates.
