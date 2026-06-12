# Security Policy

## Reporting a vulnerability

Please report security issues **privately** — do not open a public issue for a
suspected vulnerability.

- Preferred: open a private vulnerability report via GitHub Security Advisories
  ("Report a vulnerability" on the repository's **Security** tab).
- Or email **will@akasecurity.io**.

Please include what the issue is, how to reproduce it, and the impact you see. We
aim to acknowledge reports within a few business days.

## Scope and expectations

aka-claude-tools layers guards onto Claude Code. Two things worth knowing before you
report:

- **The egress guards are defense-in-depth, not a sandbox.** They raise the cost of
  an accidental leak; they do not make exfiltration impossible. Known, documented
  limitations (the Bash scan's outbound-tool scope, heuristic/regex detection,
  fail-open behavior) are described in the README under "What the egress guards do
  and don't catch" — these are by design, not vulnerabilities.
- **In scope:** ways the installer or hooks could damage a user's system or config,
  exfiltrate data, auto-approve something they shouldn't, or bypass the credential
  deny-list in a way the docs claim is protected.

## Supported versions

This project is distributed from `main`. Fixes land on `main`; there are no
long-term support branches.
