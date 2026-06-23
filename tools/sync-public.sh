#!/usr/bin/env bash
# sync-public.sh — gated mirror of this private dev repo's main onto the PUBLIC
# upstream (aka-claude-tools). Encodes the dev→public protocol in one place so
# every trigger (the manual GitHub Action, or a hand-run) applies the same rails:
#
#   1. fast-forward ONLY — abort if public/main has diverged from dev/main
#      (never force; divergence is a human decision).
#   2. leak gate — tools/audit-history.sh must pass (exit 0) over the exact
#      history about to be published; nothing un-scrubbed ever reaches public.
#   3. then push main + tags.
#
# Idempotent: a no-op when already in sync. Safe to re-run.
#
# Env (all optional, sane defaults):
#   DEV_REMOTE   dev remote name           (default: origin)
#   PUB_REMOTE   public remote name        (default: public)
#   PUB_URL      public URL — added as PUB_REMOTE if that remote is absent
#   SYNC_BRANCH  branch to mirror          (default: main)
#   RUN_TESTS=1  also run tests/run.sh before pushing (default: 0)
#   DRY_RUN=1    run every gate but do NOT push (default: 0)
#   AKA_LEAK_EXTRA  operator-identifier regex for the leak gate (see leak-lib.sh)
set -euo pipefail

DEV_REMOTE="${DEV_REMOTE:-origin}"
PUB_REMOTE="${PUB_REMOTE:-public}"
PUB_URL="${PUB_URL:-}"
BRANCH="${SYNC_BRANCH:-main}"
DRY_RUN="${DRY_RUN:-0}"
RUN_TESTS="${RUN_TESTS:-0}"

cd "$(git rev-parse --show-toplevel)"

# Ensure the public remote exists (add from PUB_URL if needed).
if ! git remote get-url "$PUB_REMOTE" >/dev/null 2>&1; then
  [ -n "$PUB_URL" ] || { echo "sync-public: no '$PUB_REMOTE' remote and PUB_URL unset" >&2; exit 2; }
  git remote add "$PUB_REMOTE" "$PUB_URL"
fi

echo "== fetch =="
# --force aligns local tags to the dev remote, so a divergent local tag of the same
# name can't publish an object different from the canonical one on the dev remote.
git fetch --tags --force "$DEV_REMOTE" "$BRANCH"
git fetch "$PUB_REMOTE" "$BRANCH" 2>/dev/null || true   # public branch may be empty on first seed

dev_sha="$(git rev-parse "$DEV_REMOTE/$BRANCH")"

# Fast-forward-only guard: public/main must be an ancestor of dev/main. (The
# "already in sync" no-op is deferred until AFTER tag reconciliation below, so
# stale/extra public tags are still caught when the branch tip already matches.)
branch_in_sync=0
if git rev-parse --verify --quiet "$PUB_REMOTE/$BRANCH" >/dev/null; then
  pub_sha="$(git rev-parse "$PUB_REMOTE/$BRANCH")"
  if [ "$pub_sha" = "$dev_sha" ]; then
    branch_in_sync=1
  elif ! git merge-base --is-ancestor "$pub_sha" "$dev_sha"; then
    echo "sync-public: ABORT — $PUB_REMOTE/$BRANCH ($pub_sha) is NOT an ancestor of" >&2
    echo "  $DEV_REMOTE/$BRANCH ($dev_sha): the public history has diverged." >&2
    echo "  Resolve by hand; never force-push the public repo." >&2
    exit 1
  else
    echo "fast-forward ok: $pub_sha -> $dev_sha"
  fi
else
  echo "note: $PUB_REMOTE/$BRANCH absent — first push"
fi

# The leak gate's operator-identifier scan is only active when identifiers are
# loaded (AKA_LEAK_EXTRA or tools/leak-patterns.local). With neither, audit-history
# silently checks generic secret SHAPES only — a quietly-weakened gate. Refuse to
# publish in that state rather than ship with the operator-identifier scan disabled.
if [ -z "${AKA_LEAK_EXTRA:-}" ] && [ ! -f tools/leak-patterns.local ]; then
  echo "sync-public: ABORT — no operator-identifier leak patterns loaded." >&2
  echo "  Set AKA_LEAK_EXTRA (a CI secret) or tools/leak-patterns.local before publishing;" >&2
  echo "  otherwise the gate would scan for generic secret shapes only." >&2
  exit 2
fi

echo "== leak gate (audit-history over the commit history reachable from $BRANCH) =="
bash tools/audit-history.sh --repo . --ref "$dev_sha"

# ── publish manifest ─────────────────────────────────────────────────────────
# The published refset MUST equal the audited refset. A blanket `git push --tags`
# breaks that: it ships every local tag — including tags off $BRANCH, tags peeling
# to non-commits, and stale local-only tags — whose objects the commit audit above
# never scanned. So publish ONLY tags that are BOTH (a) present on the dev remote
# AND (b) point at a commit reachable from $dev_sha. Off-main / non-commit / local-
# only tags are excluded by construction, so nothing unaudited reaches public.
remote_tags="$(git ls-remote --tags --refs "$DEV_REMOTE" 2>/dev/null | sed 's#.*refs/tags/##')"
pub_tags=()
while IFS= read -r t; do
  [ -n "$t" ] || continue
  printf '%s\n' "$remote_tags" | grep -qxF -- "$t" || continue   # must exist on the dev remote
  pub_tags+=("$t")
done < <(git tag --merged "$dev_sha" 2>/dev/null)                 # must be reachable from $BRANCH

# ── tag gate ─────────────────────────────────────────────────────────────────
# A tag push also publishes the tag NAME (refs/tags/<name>) and, for an annotated
# tag, the whole tag OBJECT — which carries the tagger identity (name/email) AND
# the message, neither covered by the commit-history audit. Scan both the name and
# the full object against the same FAIL set (secret shapes + operator identifiers).
# shellcheck source=tools/leak-lib.sh
source tools/leak-lib.sh
fail_re="$LEAK_SECRETS"
[ -n "${LEAK_EXTRA:-}" ] && fail_re="$fail_re|$LEAK_EXTRA"
tag_leak=0
tag_refspecs=()
for t in ${pub_tags[@]+"${pub_tags[@]}"}; do
  # Resolve the tag's OID ONCE and use it for both the scan and the push, so the
  # object published is exactly the object audited (no gate→push TOCTOU; symmetric
  # with the branch, which is pinned to $dev_sha rather than a mutable ref name).
  oid="$(git rev-parse --verify --quiet "refs/tags/$t")" || {
    echo "sync-public: cannot resolve tag: $t" >&2; tag_leak=1; continue; }
  # -e: $fail_re starts with '-----BEGIN…', which grep would otherwise read as options.
  if printf '%s' "$t" | grep -qE -e "$fail_re"; then
    echo "sync-public: leak pattern in tag NAME: $t" >&2; tag_leak=1
  fi
  # cat-file -p on the OID shows the exact object pushed: for an annotated tag the
  # tag object (tagger header + message + signature); for a lightweight tag the
  # (already-audited) commit it points to.
  obj="$(git cat-file -p "$oid" 2>/dev/null || true)"
  if [ -n "$obj" ] && printf '%s\n' "$obj" | grep -qE -e "$fail_re"; then
    echo "sync-public: leak pattern in tag OBJECT (tagger/message): $t" >&2; tag_leak=1
  fi
  tag_refspecs+=( "$oid:refs/tags/$t" )   # pinned to the audited object
done
[ "$tag_leak" = 0 ] || { echo "sync-public: ABORT — tag name/object leak; not publishing." >&2; exit 1; }

# ── destination reconciliation ───────────────────────────────────────────────
# The invariant is over the PUBLISHED STATE, not just this push. A tag already on
# public but OUTSIDE the audited manifest (e.g. a stray from an earlier `--tags`
# or a manual test) is an unaudited published ref — surface it and refuse rather
# than silently leave it published. We never auto-delete public refs (no surprise
# deletions on the irreversible target); the operator reconciles deliberately.
pub_remote_lines="$(git ls-remote --tags --refs "$PUB_REMOTE" 2>/dev/null || true)"
pub_remote_tags="$(printf '%s\n' "$pub_remote_lines" | sed 's#.*refs/tags/##' | grep -v '^$' || true)"
extra=""
missing=0
while IFS= read -r pt; do
  [ -n "$pt" ] || continue
  printf '%s\n' ${pub_tags[@]+"${pub_tags[@]}"} | grep -qxF -- "$pt" && continue
  extra="$extra $pt"
done <<EOF
$pub_remote_tags
EOF
if [ -n "${extra# }" ]; then
  echo "sync-public: ABORT — public has tag(s) outside the audited manifest:$extra" >&2
  echo "  Unaudited published refs. After confirming they are intended, remove them" >&2
  echo "  ('git push $PUB_REMOTE :refs/tags/<name>') or add them to the dev remote, then re-run." >&2
  exit 1
fi
# Any manifest tag NOT already on public at its audited oid means there is work to do.
for spec in ${tag_refspecs[@]+"${tag_refspecs[@]}"}; do
  spec_oid="${spec%%:*}"; spec_name="${spec#*:refs/tags/}"
  cur="$(printf '%s\n' "$pub_remote_lines" | awk -v n="refs/tags/$spec_name" '$2==n{print $1}')"
  [ "$cur" = "$spec_oid" ] || missing=1
done

# Genuine no-op only when the branch tip matches AND every audited tag is already
# published at its audited object — so tag drift can't hide behind an in-sync tip.
if [ "$branch_in_sync" = 1 ] && [ "$missing" = 0 ]; then
  echo "already in sync at $dev_sha (+${#pub_tags[@]} tag(s)) — nothing to do"
  exit 0
fi

if [ "$RUN_TESTS" = 1 ]; then
  echo "== flow suite =="
  bash tests/run.sh
fi

# Exact push refset: $BRANCH (pinned to $dev_sha) + the audited tags (each pinned
# to its scanned OID, NEVER `--tags`), pushed --atomic so the public state is a
# single all-or-nothing transaction that equals exactly what was audited.
push_refs=( "$dev_sha:refs/heads/$BRANCH" )
push_refs+=( ${tag_refspecs[@]+"${tag_refspecs[@]}"} )

if [ "$DRY_RUN" = 1 ]; then
  echo "DRY_RUN — gates passed; would atomically push $dev_sha + ${#pub_tags[@]} tag(s) to $PUB_REMOTE/$BRANCH:"
  if [ "${#pub_tags[@]}" -gt 0 ]; then printf '  tag: %s\n' "${pub_tags[@]}"; fi
  exit 0
fi

echo "== push (atomic; fast-forward; no force) =="
git push --atomic "$PUB_REMOTE" "${push_refs[@]}"
echo "SYNCED $DEV_REMOTE/$BRANCH -> $PUB_REMOTE/$BRANCH @ $dev_sha (+${#pub_tags[@]} tag(s))"
