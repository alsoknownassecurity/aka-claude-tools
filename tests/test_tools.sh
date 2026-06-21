#!/usr/bin/env bash
# Maintainer tooling (tools/) — the pre-publish leak gates. These are what keep
# secrets/operator-traces out of a repo destined to go public, so they must
# actually fire. All against sandbox repos; no real history is scanned.
#
# Secret SHAPES below are assembled from fragments at runtime (e.g. "AKIA"+...) so
# this committed test file never itself carries a token a future history audit
# would flag.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_tools:"

LL="$REPO_ROOT/tools/leak-lib.sh"
AR="$REPO_ROOT/tools/audit-history.sh"
GR="$REPO_ROOT/tools/graduate.sh"
AWS="AKIA""IOSFODNN7EXAMPLE"          # AWS access-key shape (well-known docs example)
ANT="sk-ant-""FAKEKEY00000000000000"  # Anthropic key shape

# ── leak-lib.sh: pattern library is sound ────────────────────────────────────
# NB: the patterns start with '-----BEGIN', so grep must take them via -e (a bare
# "$LEAK_SECRETS" is parsed as an option) — exactly how the real tools invoke grep.
assert_ok   "leak-lib flags an AWS key shape" \
  bash -c "source '$LL'; printf %s '$AWS' | grep -qE -e \"\$LEAK_SECRETS\""
assert_ok   "leak-lib flags an Anthropic key shape" \
  bash -c "source '$LL'; printf %s '$ANT' | grep -qE -e \"\$LEAK_SECRETS\""
assert_fail "leak-lib passes benign text" \
  bash -c "source '$LL'; printf %s 'just a normal sentence' | grep -qE -e \"\$LEAK_RE\""
assert_ok   "AKA_LEAK_EXTRA folds operator patterns into LEAK_RE" \
  bash -c "export AKA_LEAK_EXTRA='ZZ_op_marker_42'; source '$LL'; printf %s 'x ZZ_op_marker_42 y' | grep -qE -e \"\$LEAK_RE\""

# ── audit-history.sh: history gate fails on a planted secret, passes when clean ─
gitc() { git -c user.email=t@t -c user.name=t -C "$1" "${@:2}"; }

clean="$(sandbox)/clean"; git init -q "$clean"
echo "just project docs" > "$clean/README.md"; gitc "$clean" add .; gitc "$clean" commit -qm "init"
assert_ok   "audit passes a clean history" "$AR" --repo "$clean" --ref HEAD

dirty="$(sandbox)/dirty"; git init -q "$dirty"
printf 'aws_key=%s\n' "$AWS" > "$dirty/creds.txt"; gitc "$dirty" add .; gitc "$dirty" commit -qm "oops"
assert_fail "audit FAILS on a secret buried in history" "$AR" --repo "$dirty" --ref HEAD

# A secret only ever in a COMMIT MESSAGE (never in a blob) is still caught.
msgrepo="$(sandbox)/msg"; git init -q "$msgrepo"
echo ok > "$msgrepo/f"; gitc "$msgrepo" add .; gitc "$msgrepo" commit -qm "add key $ANT"
assert_fail "audit FAILS on a secret in a commit message" "$AR" --repo "$msgrepo" --ref HEAD

# ── graduate.sh: argument validation guards before touching any repo ─────────
assert_ok   "graduate --help exits 0" bash -c "AKA_PUBLIC=/nope AKA_DEV=/nope '$GR' --help"
assert_fail "graduate requires --branch" bash -c "AKA_PUBLIC=/nope AKA_DEV=/nope '$GR'"

t_summary
