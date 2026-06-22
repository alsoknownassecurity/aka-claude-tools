#!/usr/bin/env bash
# Scenario (scn_shell_audit): the shell-audit auditor's CORE promise — never print a
# secret VALUE, walk the full source chain (warn when it can't), and stay read-only.
# Guards the dual-review findings on config/skills/shell-audit/audit.sh:
#   F1 — every shape in $shape_re is also redacted (detection↔redaction parity); a
#        github_pat_ was detected-but-not-redacted before. This is the F6 self-test:
#        if you add a shape to shape_re, add a sample below or this fails.
#   F7 — the persistence section redacts too (a token in a flagged `curl … | sh`).
#   F3 — quoted / keyword-at-start secret-named assignments are detected AND redacted,
#        without false-positiving a quoted variable reference.
#   F2 — a variable-built/unresolvable `source` is reported (not silently skipped);
#        a relative include is resolved against the including file's dir.
#   F5 — git drift check neutralizes a hostile repo-set core.fsmonitor (no code exec).
#   read-only — audited files are byte-identical after the run.
#
# Fully sandboxed: fake rc files under a mktemp dir; never touches a real profile.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_shell_audit:"

AUDIT="$REPO_ROOT/config/skills/shell-audit/audit.sh"

# ── F1/F6: one token per $shape_re shape; NONE may survive verbatim in the output ──
SB="$(sandbox)"; RC="$SB/rc"
# Each value carries a unique, shape-valid body; redaction must remove the full token.
cat > "$RC" <<'EOF'
AWS_THING=AKIAABCDEFGHIJKLMNOP
ANTHROPIC=sk-ant-abcdefghij0123456789xy
OPENAI=sk-abcdefghij0123456789zzzz
GHTOKEN=ghp_abcdefghij0123456789ABCD
GHFINE=github_pat_abcdefghij0123456789ABCDEFG
SLACK=xoxb-0123456789-abcdefABCDEFxy
GOOGLE=AIzaABCDEFGHIJKLMNOPQRSTUVWXYZ0123456
GITLAB=glpat-abcdefghij0123456789xy
JWTISH=eyJabcdefghij.eyJklmnopqrst
PEMLINE="-----BEGIN RSA PRIVATE KEY-----"
QUOTED_API_KEY="quotedsecretvalue12345"
lower_secret=lowercasesecretvalue99
NOTASECRET="$HOME/bin"
EOF
out="$(bash "$AUDIT" "$RC" 2>&1)"

# the verbatim secret VALUES that must NOT appear anywhere in the output
for v in AKIAABCDEFGHIJKLMNOP sk-ant-abcdefghij0123456789xy sk-abcdefghij0123456789zzzz \
         ghp_abcdefghij0123456789ABCD github_pat_abcdefghij0123456789ABCDEFG \
         xoxb-0123456789-abcdefABCDEFxy AIzaABCDEFGHIJKLMNOPQRSTUVWXYZ0123456 \
         glpat-abcdefghij0123456789xy 'eyJabcdefghij.eyJklmnopqrst' \
         'BEGIN RSA PRIVATE KEY' quotedsecretvalue12345 lowercasesecretvalue99; do
  if printf '%s' "$out" | grep -qF -- "$v"; then fail "shape value NOT leaked: $v" "leaked in output"; else pass "shape value redacted: $v"; fi
done
# detection fired (regressions for F1/F3 specifically)
printf '%s' "$out" | grep -qF 'GHFINE=github_pat_<redacted>' && pass "F1: github_pat_ detected AND redacted" || fail "F1: github_pat_ handling" "$out"
printf '%s' "$out" | grep -qF 'QUOTED_API_KEY=<redacted>' && pass "F3: quoted secret detected AND redacted" || fail "F3: quoted secret" "$out"
# quoted variable reference is NOT a secret → no false positive
printf '%s' "$out" | grep -qF 'NOTASECRET' && fail "F3: var-ref not false-flagged" "flagged" || pass "F3: quoted var-ref not false-flagged"

# ── F7: section [2] never prints the matched command body, so a secret on a flagged
# line CANNOT leak regardless of its carrier (Bearer, X-Api-Key, basic-auth url, …).
# Each line carries a unique sentinel in an ARBITRARY carrier; none may appear.
SB2="$(sandbox)"; RC2="$SB2/rc"
{ printf 'cur%s SENTbearer001 https://host-sent-a/path | s%s\n'      'l -H Authorization:Bearer' 'h'
  printf 'cur%s SENTxapikey002 https://host-sent-b/path | s%s\n'     'l -H X-Api-Key:' 'h'
  printf 'cur%s SENTtoken003 https://host-sent-c/path | s%s\n'       'l -H Authorization:token' 'h'
  printf 'wge%s "https://host-sent-d/v1?access_token=SENTurl004" -O- | ba%s\n' 't' 'sh'; } > "$RC2"
out2="$(bash "$AUDIT" "$RC2" 2>&1)"
for s in SENTbearer001 SENTxapikey002 SENTtoken003 SENTurl004; do
  printf '%s' "$out2" | grep -qF "$s" && fail "F7: persistence secret never printed ($s)" "leaked" || pass "F7: persistence secret never printed ($s)"
done
# and the command body itself is not dumped (host/url elided), only location+category
printf '%s' "$out2" | grep -qF 'host-sent-a' && fail "F7: command body not printed" "body leaked" || pass "F7: command body not printed"
printf '%s' "$out2" | grep -qF 'pipe-to-shell' && pass "F7: matched category reported" || fail "F7: category reported" "$out2"

# ── F2: unresolvable + relative source handling ───────────────────────────────
SB3="$(sandbox)"; RC3="$SB3/rc"
printf 'export REL_SECRET=relplainsecret12345\n' > "$SB3/rel.sh"
{ echo 'source "$DOTFILES/hidden.sh"'; echo 'source ./rel.sh'; } > "$RC3"
out3="$(bash "$AUDIT" "$RC3" 2>&1)"
printf '%s' "$out3" | grep -qF 'COVERAGE IS PARTIAL' && pass "F2: unresolvable source reported" || fail "F2: unresolvable source reported" "$out3"
printf '%s' "$out3" | grep -qF 'DOTFILES' && pass "F2: unresolved include named" || fail "F2: unresolved include named" "$out3"
printf '%s' "$out3" | grep -qF 'rel.sh' && pass "F2: relative include resolved + walked" || fail "F2: relative include resolved" "$out3"
printf '%s' "$out3" | grep -qF 'relplainsecret12345' && fail "F2: secret in relative include redacted" "leaked" || pass "F2: secret in relative include redacted"

# ── leak surfaces OUTSIDE the line bodies: a secret in a PATH or an unresolved
# source-line argument must also be redacted (location prints go through short()).
SB3b="$(sandbox)"; RC3b="$SB3b/rc"
# (a) a resolvable include whose FILENAME contains a token shape -> printed in graph list
secretname="github_pat_abcdefghij0123456789ABCDEFG"
printf 'alias z=1\n' > "$SB3b/$secretname.sh"
# (b) an UNRESOLVED include whose raw argument carries a token shape
{ printf 'source ./%s.sh\n' "$secretname"
  printf 'source "$UNSET_VAR/sk-ant-abcdefSECRETpath0123456.sh"\n'; } > "$RC3b"
out3b="$(bash "$AUDIT" "$RC3b" 2>&1)"
printf '%s' "$out3b" | grep -qF "$secretname" && fail "leak: token-shaped FILENAME redacted in path output" "leaked" || pass "token-shaped FILENAME redacted in path output"
printf '%s' "$out3b" | grep -qF 'sk-ant-abcdefSECRETpath0123456' && fail "leak: token in unresolved source rawline redacted" "leaked" || pass "token in unresolved source rawline redacted"

# ── F5: hostile core.fsmonitor must NOT execute during the git-drift check ─────
SB4="$(sandbox)"; RB="$SB4/repo"; mkdir -p "$RB"
printf 'alias a=b\n' > "$RB/.zshrc"
( cd "$RB" && git init -q && git add .zshrc && git -c user.email=t@t -c user.name=t commit -qm init \
    && git config core.fsmonitor 'echo FSMONITOR-EXECUTED >&2' ) >/dev/null 2>&1
errf="$SB4/err"
bash "$AUDIT" "$RB/.zshrc" >/dev/null 2>"$errf"
grep -q FSMONITOR "$errf" && fail "F5: hostile core.fsmonitor neutralized" "fsmonitor executed" || pass "F5: hostile core.fsmonitor neutralized"

# ── read-only: an audited file is byte-identical after the run ─────────────────
SB5="$(sandbox)"; RC5="$SB5/rc"
printf 'alias z=1\nexport TOKEN=abcdefghijklmnop\n' > "$RC5"
before="$(shasum "$RC5" | awk '{print $1}')"
bash "$AUDIT" "$RC5" >/dev/null 2>&1
after="$(shasum "$RC5" | awk '{print $1}')"
assert_eq "read-only: audited file unchanged" "$before" "$after"

t_summary
