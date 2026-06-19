#!/usr/bin/env bash
# aka-promote.sh — promote product artifacts from a live ~/.claude-aka profile
# into an aka-claude-tools clone, staged on a branch for a PR.
#
# WHY: install.sh COPIES config into the profile (it does not symlink), so edits
# you make live in ~/.claude-aka never flow back to the repo on their own. This
# does the reverse hop: manifest-driven (config/additions.json is the source of
# truth for what is shippable), path-remapped (profile <X> -> repo config/<X>),
# and leak-scanned so personal state (auth, memory, settings, hostnames) can
# never ride along into a public repo.
#
# It moves ONLY files an addition declares (its skill/hook/command/statusLine
# keys). Settings are MERGED into the profile's settings.json and cannot be
# reverse-copied — the script tells you to edit config/settings.base.json by hand.
#
# Usage:
#   aka-promote.sh --list                       # list addition ids in the repo
#   aka-promote.sh KEY [KEY...]                  # promote named additions
#   aka-promote.sh --all                         # promote every declared addition
#   aka-promote.sh --branch feat/x KEY           # stage on a named branch
#   aka-promote.sh --commit  --branch feat/x KEY # also commit (else just staged)
#   aka-promote.sh --kind hook KEY               # KEY is a NEW artifact (no manifest yet)
#
# Env: CLAUDE_CONFIG_DIR (profile, default ~/.claude-aka)
#      AKA_REPO          (repo clone,  default: the repo this script lives in)
set -euo pipefail

# Default the target repo to the clone this script is checked out in, so it is
# portable across every teammate's machine (override with AKA_REPO / --repo).
_SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude-aka}"
REPO="${AKA_REPO:-$(git -C "$_SELF_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$HOME/coding/libs/aka-claude-tools")}"
BRANCH="" ; DO_COMMIT=0 ; LIST=0 ; ALL=0 ; FORCE=0 ; KIND="skills"
keys=()

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
warn() { printf '\033[33mwarn:\033[0m %s\n'  "$*" >&2; }
ok()   { printf '\033[32m  ✓\033[0m %s\n'    "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2;;
    --repo)    REPO="$2";    shift 2;;
    --branch)  BRANCH="$2";  shift 2;;
    --kind)    KIND="${2%s}s"; shift 2;;   # normalize hook->hooks, skill->skills
    --commit)  DO_COMMIT=1;  shift;;
    --all)     ALL=1;        shift;;
    --list)    LIST=1;       shift;;
    --force)   FORCE=1;      shift;;        # promote despite a leak hit (rare)
    -h|--help) sed -n '2,30p' "$0"; exit 0;;
    -*)        die "unknown flag: $1";;
    *)         keys+=("$1"); shift;;
  esac
done

command -v jq >/dev/null || die "jq is required"
[ -d "$PROFILE" ] || die "profile not found: $PROFILE"
[ -d "$REPO/.git" ] || die "repo clone not found: $REPO"
ADDITIONS="$REPO/config/additions.json"
[ -f "$ADDITIONS" ] || die "manifest not found: $ADDITIONS"

if [ "$LIST" = 1 ]; then
  echo "addition ids declared in $ADDITIONS:"
  jq -r '.additions[] | "  \(.id)\t\(.name)"' "$ADDITIONS"
  exit 0
fi

if [ "$ALL" = 1 ]; then
  while IFS= read -r id; do keys+=("$id"); done < <(jq -r '.additions[].id' "$ADDITIONS")
fi
[ "${#keys[@]}" -gt 0 ] || die "name at least one addition id (or --all, --list)"

# High-precision personal-trace scan. '.claude-aka' is legitimate product
# branding and is intentionally NOT matched; example placeholders like
# /Users/jdoe are fine — we match only the operator's real identifiers.
LEAK_RE='lin\.example-user|gmail\.com|example-host|example-net|Will Lin <|aka-user@example|example-user@.*\.ts\.net|/Users/me|/home/me'

# Resolve a branch (never stage onto main — AGENTS.md forbids committing to main).
cur_branch="$(git -C "$REPO" branch --show-current 2>/dev/null || echo)"
if [ -z "$BRANCH" ]; then
  if [ "$cur_branch" = main ] || [ -z "$cur_branch" ]; then
    BRANCH="promote/$(IFS=-; echo "${keys[*]}")"
    warn "on '$cur_branch' — auto-creating branch '$BRANCH' (override with --branch)"
  else
    BRANCH="$cur_branch"   # use the feature branch already checked out
  fi
fi
if [ "$BRANCH" != "$cur_branch" ]; then
  git -C "$REPO" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null \
    && git -C "$REPO" checkout -q "$BRANCH" \
    || git -C "$REPO" checkout -q -b "$BRANCH"
fi
ok "staging on branch: $BRANCH"

copied=() ; manifest_gaps=()

copy_one() {  # $1 = repo-relative-under-config path, e.g. skills/conductor
  local rel="$1" src="$PROFILE/$1" dst="$REPO/config/$1"
  if [ ! -e "$src" ]; then warn "profile has no $rel — skipped"; return; fi
  if [ -d "$src" ]; then
    rm -rf "$dst"; mkdir -p "$(dirname "$dst")"; cp -R "$src" "$dst"
  else
    mkdir -p "$(dirname "$dst")"; cp "$src" "$dst"
  fi
  copied+=("config/$rel")
  ok "config/$rel  ←  profile/$rel"
}

for key in "${keys[@]}"; do
  obj="$(jq -c --arg id "$key" '.additions[] | select(.id==$id)' "$ADDITIONS")"
  if [ -z "$obj" ]; then
    # No manifest entry yet — treat as a NEW artifact of --kind (default skills).
    copy_one "$KIND/$key"
    manifest_gaps+=("$key")
    continue
  fi
  # Pull every file-bearing key the addition declares.
  while IFS= read -r p; do [ -n "$p" ] && copy_one "$p"; done < <(
    echo "$obj" | jq -r '.skill, .hook, .command, .statusLine | select(. != null)'
  )
  # Settings can't be reverse-copied (merged into the profile's settings.json).
  s="$(echo "$obj" | jq -r '.settings // empty')"
  [ -n "$s" ] && warn "$key declares settings '$s' — NOT auto-synced; edit config/$s by hand if it changed"
done

[ "${#copied[@]}" -gt 0 ] || die "nothing copied"

# Leak scan over exactly what we copied.
echo
hits="$(cd "$REPO" && grep -rInE "$LEAK_RE" "${copied[@]}" 2>/dev/null || true)"
if [ -n "$hits" ]; then
  warn "personal-trace hits in promoted files:"; echo "$hits" >&2
  [ "$FORCE" = 1 ] || die "refusing to stage a leak (use --force to override after review)"
  warn "--force given: staging despite hits"
else
  ok "leak scan clean"
fi

git -C "$REPO" add -- "${copied[@]}"
echo; echo "staged diff:"; git -C "$REPO" --no-pager diff --cached --stat

if [ "${#manifest_gaps[@]}" -gt 0 ]; then
  echo; warn "NEW artifacts with no manifest entry: ${manifest_gaps[*]}"
  warn "add an addition to config/additions.json so install.sh ships them."
fi

if [ "$DO_COMMIT" = 1 ]; then
  git -C "$REPO" commit -q -m "feat: promote $(IFS=,; echo "${keys[*]}") from profile"
  echo; ok "committed on $BRANCH"
  git -C "$REPO" --no-pager log --oneline -1
fi

echo
echo "next:  cd $REPO && git -C . diff --cached   # review"
echo "       git commit  (if not --commit)  &&  git push -u origin $BRANCH"
echo "       open a PR against the upstream you're contributing to."
