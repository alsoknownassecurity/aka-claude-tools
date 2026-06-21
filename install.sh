#!/usr/bin/env bash
# aka-claude-tools installer
# ──────────────────────
# Creates one or more ISOLATED Claude Code config folders, optionally seeded from
# an existing config (defaults to your LIVE config dir — $CLAUDE_CONFIG_DIR, else
# ~/.claude — but you can pick any folder or a backup), layers on the aka-claude-tools
# additions you select, and wires a shell alias so you can launch each by name.
#
# Mechanism: Claude Code reads its config dir from $CLAUDE_CONFIG_DIR. Each folder
# is fully independent (own settings, hooks, agents, sessions). The alias just
# exports that variable before launching `claude`:
#
#     alias aka='CLAUDE_CONFIG_DIR="$HOME/.claude-aka" claude'
#
# Re-run any time to add another config folder. Idempotent: re-running for the
# same folder/alias updates in place instead of duplicating. Idempotent BOTH
# ways: unchecking an addition you previously installed UNINSTALLS it — its
# hook/command/skill files and its settings contributions (hook registrations,
# statusLine, and the permission/env rules it shipped) are removed. Your own
# rules, hooks, and files are never touched.
#
# The target can also be the DEFAULT ~/.claude: the installer offers to move it
# to a timestamped backup, rebuild it clean with the selected additions, and
# migrate your picks back from the backup. No alias is written for the default
# dir (plain `claude` uses it) and your login survives — ~/.claude.json lives at
# $HOME, Keychain auth is keyed to the unchanged dir path, and a file-based
# .credentials.json is copied back from the backup.
#
# UPGRADES PRESERVE YOUR STATE. An upgrade is never a fresh install: a clean
# rebuild automatically restores the profile's OWN runtime state from the backup
# — conversations, memory/, prompt history, todos, tasks, plus CLAUDE.md and your
# settings.json — then re-applies the current kit files on top. Only secret-bearing
# caches (credentials are restored separately; shell-snapshots / paste-cache /
# file-history / session-env are left in the backup) sit outside that restore.
# The blast radius of an upgrade is the kit-managed surface, not your data.
#
# Flags:
#   --defaults         non-interactive; accept every default (config ~/.claude-aka,
#                      alias `aka`, recommended additions, no copy of existing config).
#   --no-auth-inherit  do NOT seed the new profile's .claude.json from your existing
#                      login (use when the profile is for a DIFFERENT account).
#   --clean            force the back-up + clean-rebuild path (default for an existing
#                      non-default profile is layer-in-place). State is restored either
#                      way; --clean additionally refreshes kit-managed FILES (hooks,
#                      commands, skills) to the current version rather than leaving the
#                      old ones in place. Settings permissions are reconciled (adopt
#                      new / retire dropped) in both paths.

set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_SRC="$REPO_DIR/config"
# History of permission rules the kit has retired — drives upgrade reconciliation
# (see reconcile_managed_perms). Missing file degrades to "nothing retired".
RETIRED_PERMS="$(cat "$CONFIG_SRC/managed-permissions.json" 2>/dev/null || printf '{}')"
# shellcheck source=shared/lib/common.sh
source "$REPO_DIR/shared/lib/common.sh"

SEED_AUTH=1
CT_CLEAN=0
for arg in "$@"; do
  case "$arg" in
    --defaults)        export CT_NONINTERACTIVE=1 ;;
    --no-auth-inherit) SEED_AUTH=0 ;;
    --clean)           CT_CLEAN=1 ;;
  esac
done

# ── rebuild safety net ───────────────────────────────────────────────────────
# The default-dir rebuild moves ~/.claude to a timestamped backup before
# recreating it. Between that mv and the finished rebuild, an interrupt (Ctrl-C)
# or a mid-flow failure under `set -e` would otherwise leave ~/.claude as a
# broken half-built dir while the real config sits silently in the backup —
# plain `claude` would then launch a config with no settings/memory. This trap
# restores the backup if the rebuild didn't complete, making the operation
# all-or-nothing. Harmless on every non-rebuild path (the guard vars stay empty).
_CT_REBUILD_BACKUP=""
_CT_REBUILD_TARGET=""
_CT_REBUILD_DONE=0
_CT_ROLLBACK_RAN=0
ct_rebuild_rollback() {
  [ "$_CT_ROLLBACK_RAN" = "1" ] && return 0
  _CT_ROLLBACK_RAN=1
  [ -n "$_CT_REBUILD_BACKUP" ] || return 0      # no rebuild was in progress
  [ "$_CT_REBUILD_DONE" = "1" ] && return 0     # rebuild finished cleanly
  [ -d "$_CT_REBUILD_BACKUP" ] || return 0      # backup gone / mv never happened
  warn ""
  warn "Interrupted before the rebuild finished — restoring ${_CT_REBUILD_TARGET/#$HOME/~}."
  [ -d "$_CT_REBUILD_TARGET" ] && rm -rf "$_CT_REBUILD_TARGET" 2>/dev/null
  if mv "$_CT_REBUILD_BACKUP" "$_CT_REBUILD_TARGET" 2>/dev/null; then
    ok "Restored ${_CT_REBUILD_TARGET/#$HOME/~} from the backup — nothing was left behind."
  else
    warn "Could not auto-restore. Your original config is intact at: $_CT_REBUILD_BACKUP"
    warn "Recover manually: rm -rf \"$_CT_REBUILD_TARGET\" && mv \"$_CT_REBUILD_BACKUP\" \"$_CT_REBUILD_TARGET\""
  fi
}
trap 'ct_rebuild_rollback; exit 130' INT
trap 'ct_rebuild_rollback; exit 143' TERM
trap 'ct_rebuild_rollback; exit 129' HUP
# Preserve the real exit status — a bare EXIT trap would otherwise overwrite $?
# with the trap body's status and mask a clean (0) or failing exit.
trap 'rc=$?; ct_rebuild_rollback; exit $rc' EXIT

# ── preflight ────────────────────────────────────────────────────────────────
# jq drives the whole settings merge — required. Offer to install it via the
# detected package manager; abort if we can't get it.
ensure_dep jq "jq (required)" 1
command -v claude >/dev/null 2>&1 || warn "claude CLI not found on PATH — the alias will still be written, but install Claude Code to use it."
# bun (command-guard) and trufflehog (web-egress) are checked/offered when those
# additions are selected — see the build step below.

say ""
printf '%s%s aka-claude-tools installer %s\n' "$C_BOLD" "$C_BLU" "$C_RST"
say "${C_DIM}Isolated Claude config folders + aliases, with the must-have additions.${C_RST}"

# ── settings merge ───────────────────────────────────────────────────────────
# merge_settings <existing.json|''> <additions.json-string>  -> merged JSON on stdout
# Deep-merges (later wins) but UNIONS permission arrays and hook-event arrays so a
# copied-in existing config never loses its own denies/hooks.
merge_settings() {
  local existing="$1" additions="$2"
  [ -z "$existing" ] && existing='{}'
  [ -z "$additions" ] && additions='{}'
  jq -n --argjson e "$existing" --argjson a "$additions" '
    ($e * $a)
    | ( (($e.permissions // {}) * ($a.permissions // {})) as $pbase
        | reduce ("allow","deny","ask") as $k ($pbase;
            ( ((($e.permissions[$k]) // []) + (($a.permissions[$k]) // [])) | unique ) as $m
            | if ($m | length) > 0 then .[$k] = $m else . end)
      ) as $perms
    | (if ($perms | length) > 0 then .permissions = $perms else del(.permissions) end)
    | ( ($e.hooks // {}) as $eh | ($a.hooks // {}) as $ah
        | (($eh | keys) + ($ah | keys) | unique) as $evts
        | reduce $evts[] as $evt ({};
            .[$evt] = ((($eh[$evt] // []) + ($ah[$evt] // [])) | unique_by(tojson)))
      ) as $hooks
    | (if ($hooks | length) > 0 then .hooks = $hooks else del(.hooks) end)
    | del(.["$comment"])
  '
}

# idxs_to_subarray '<json-array>' "1 3 4"  → JSON array of those 1-based elements
# (empty selection → []). Used to turn a user's pick of line numbers into a set.
idxs_to_subarray() {
  local arr="$1" idxs="$2"
  [ -z "$idxs" ] && { printf '[]'; return; }
  local jqidx; jqidx="$(printf '%s\n' $idxs | jq -s 'map(. - 1)')"
  jq -cn --argjson a "$arr" --argjson i "$jqidx" '[ $i[] as $k | $a[$k] ]'
}

# ── uninstall a deselected addition ──────────────────────────────────────────
# A plain merge only ADDS, so unchecking an addition on a re-run used to leave
# its files and settings behind forever. These helpers remove exactly what an
# addition contributed — driven by config/additions.json (.hook/.command/.skill/
# .settings/.statusLine) so they can't drift from the install logic. All are
# idempotent: pruning something already absent is a no-op.

# Remove every settings hook registration whose command references basename $1,
# then drop any event left empty. Kit hooks are matched by their unique file
# name, so a user's own hooks (different command) are never touched.
prune_hook_regs() {
  jq --arg b "$1" '
    if (.hooks|type)=="object" then
      (.hooks |= ( to_entries
        | map(.value |= map(select(((.hooks // []) | map(.command // "") | any(contains($b))) | not)))
        | map(select((.value|type)=="array" and (.value|length) > 0))
        | from_entries ))
      | (if (.hooks // {}) == {} then del(.hooks) else . end)
    else . end'
}

# Drop .statusLine if its command references basename $1.
prune_statusline() {
  jq --arg b "$1" 'if ((.statusLine.command // "") | contains($b)) then del(.statusLine) else . end'
}

# Subtract an addition's shipped permission arrays + env keys (read from its
# payload file $1) from the settings on stdin. Set-difference on permission
# arrays and key-removal on env — only the exact rules the kit shipped go; any
# the user also keeps elsewhere in their own rules are unaffected (the kit rule
# is a duplicate the union would re-add anyway).
prune_perms_env() {
  local p; p="$(jq -c '{permissions: (.permissions // {}), env: (.env // {})}' "$1" 2>/dev/null || printf '{}')"
  jq --argjson p "$p" '
    ( if (.permissions|type)=="object" then
        reduce ("allow","deny","ask") as $k (.;
          if (.permissions[$k]?) and ($p.permissions[$k]?) then
            (.permissions[$k] = (.permissions[$k] - $p.permissions[$k]))
            | (if (.permissions[$k]|length) == 0 then del(.permissions[$k]) else . end)
          else . end)
        | (if (.permissions // {}) == {} then del(.permissions) else . end)
      else . end )
    | ( if (.env|type)=="object" then
          (.env |= with_entries(select((.key) as $k | ($p.env | has($k)) | not)))
          | (if (.env // {}) == {} then del(.env) else . end)
        else . end )'
}

# addition_owned_paths <id> <config_dir> → echo the files/dirs the addition owns.
addition_owned_paths() {
  local id="$1" cfg="$2" key rel
  for key in hook command statusLine skill; do
    rel="$(jq -r --arg i "$id" --arg k "$key" '.additions[] | select(.id==$i) | .[$k] // ""' "$CONFIG_SRC/additions.json")"
    [ -n "$rel" ] && echo "$cfg/$rel"
  done
}

# prune_addition_from_settings <id>  (settings json on stdin → pruned on stdout)
# Applies the relevant prunes for one addition based on its additions.json entry.
prune_addition_from_settings() {
  local id="$1" s hook sline setf
  s="$(cat)"
  hook="$(jq -r --arg i "$id" '.additions[] | select(.id==$i) | .hook // ""'       "$CONFIG_SRC/additions.json")"
  sline="$(jq -r --arg i "$id" '.additions[] | select(.id==$i) | .statusLine // ""' "$CONFIG_SRC/additions.json")"
  setf="$(jq -r --arg i "$id" '.additions[] | select(.id==$i) | .settings // ""'   "$CONFIG_SRC/additions.json")"
  [ -n "$hook" ]  && s="$(printf '%s' "$s" | prune_hook_regs "$(basename "$hook")")"
  [ -n "$sline" ] && s="$(printf '%s' "$s" | prune_statusline "$(basename "$sline")")"
  [ -n "$setf" ] && [ -f "$CONFIG_SRC/$setf" ] && s="$(printf '%s' "$s" | prune_perms_env "$CONFIG_SRC/$setf")"
  printf '%s' "$s"
}

# ── managed-permission reconciliation ────────────────────────────────────────
# A plain settings merge UNIONS permission arrays, so a rule the kit used to ship
# but has since dropped can never be removed by re-running the installer — it
# lingers forever in an upgraded profile (and a deny the kit no longer wants stays
# active). This reconciles the kit-managed arrays (deny/allow/ask) before the
# merge, so on an upgrade the engineer SEES the differences and chooses per-rule:
#   • new rules this version adds        → adopted by default (skip individually)
#   • rules this version no longer ships → retired by default (keep individually)
#   • anything the kit never shipped (your own rules) → always left untouched
# "No longer ships" = a string listed in config/managed-permissions.json .retired[]
# that is absent from the current secure-settings / rtk-allowlist payload. Honors
# CT_NONINTERACTIVE (takes the defaults: adopt new, retire dropped) and always
# logs the outcome so an upgrade never changes rules silently.
# Sets globals RECON_EXISTING / RECON_ADD for the caller to merge.
RECON_EXISTING='{}'; RECON_ADD='{}'
reconcile_managed_perms() {
  local existing="$1" add="$2"
  RECON_EXISTING="$existing"; RECON_ADD="$add"
  # Nothing shipped this run, or no prior settings → plain merge already does the
  # right thing (there is nothing to retire and every kit rule is a clean add).
  [ "$(jq -r '(.permissions // {}) | length' <<<"$add")" = "0" ] && return 0
  [ "$(jq -r '(.permissions // {}) | length' <<<"$existing")" = "0" ] && return 0

  local key arr_new arr_exist arr_ret added retired_present n_add n_ret shown=0
  for key in deny allow ask; do
    arr_new="$(jq -c --arg k "$key" '.permissions[$k] // []' <<<"$add")"
    # Only reconcile arrays the kit actually provides this run — never touch an
    # array the engineer selected no addition for.
    [ "$(jq 'length' <<<"$arr_new")" = "0" ] && continue
    arr_exist="$(jq -c --arg k "$key" '.permissions[$k] // []' <<<"$existing")"
    arr_ret="$(jq -c --arg k "$key" '(.retired[$k]) // []' <<<"$RETIRED_PERMS")"

    added="$(jq -cn --argjson n "$arr_new" --argjson e "$arr_exist" '$n - $e')"
    # Retire candidates = existing rules that the kit once shipped (in .retired)
    # AND no longer ships now. Intersection of existing with the retired history.
    retired_present="$(jq -cn --argjson e "$arr_exist" --argjson r "$arr_ret" '$e - ($e - $r)')"
    n_add="$(jq 'length' <<<"$added")"; n_ret="$(jq 'length' <<<"$retired_present")"
    [ "$n_add" = "0" ] && [ "$n_ret" = "0" ] && continue

    if [ "$shown" = "0" ]; then
      isay ""; isay "${C_BOLD}Reconciling permissions with this version${C_RST} ${C_DIM}(your own rules are kept untouched)${C_RST}"
      shown=1
    fi
    isay ""; isay "  ${C_BOLD}permissions.${key}${C_RST}"

    local skip_idxs="" keep_idxs="" i e sel
    if [ "$n_add" != "0" ]; then
      isay "    ${C_GRN}+ ${n_add} new rule(s) in this version:${C_RST}"
      i=1; while IFS= read -r e; do isay "        ${C_DIM}${i})${C_RST} ${e}"; i=$((i+1)); done < <(jq -r '.[]' <<<"$added")
      prompt sel "    skip any? (numbers to SKIP, Enter = adopt all):" ""
      skip_idxs="$(parse_selection "$sel" "$n_add")"
    fi
    if [ "$n_ret" != "0" ]; then
      isay "    ${C_YLW}- ${n_ret} rule(s) this version no longer ships:${C_RST}"
      i=1; while IFS= read -r e; do isay "        ${C_DIM}${i})${C_RST} ${e}"; i=$((i+1)); done < <(jq -r '.[]' <<<"$retired_present")
      prompt sel "    keep any? (numbers to KEEP, Enter = drop all):" ""
      keep_idxs="$(parse_selection "$sel" "$n_ret")"
    fi

    local skip_added keep_retired drop_retired
    skip_added="$(idxs_to_subarray "$added" "$skip_idxs")"
    keep_retired="$(idxs_to_subarray "$retired_present" "$keep_idxs")"
    drop_retired="$(jq -cn --argjson r "$retired_present" --argjson k "$keep_retired" '$r - $k')"

    # Apply: drop skipped additions from the incoming kit set, and drop the
    # retired rules the engineer didn't keep from the existing set. The plain
    # merge then unions what's left — preserving every user rule and kept rule.
    RECON_ADD="$(jq -c --arg k "$key" --argjson skip "$skip_added" \
      '.permissions[$k] = ((.permissions[$k] // []) - $skip)' <<<"$RECON_ADD")"
    RECON_EXISTING="$(jq -c --arg k "$key" --argjson drop "$drop_retired" \
      'if (.permissions[$k]?) then .permissions[$k] = (.permissions[$k] - $drop) else . end' <<<"$RECON_EXISTING")"

    local n_adopted n_retired
    n_adopted="$(jq -n --argjson a "$added" --argjson s "$skip_added" '($a - $s) | length')"
    n_retired="$(jq 'length' <<<"$drop_retired")"
    [ "$n_adopted" != "0" ] && ok "permissions.${key}: adopted ${n_adopted} new rule(s)"
    [ "$n_retired" != "0" ] && ok "permissions.${key}: retired ${n_retired} rule(s) this version no longer ships"
  done
}

# ── auth inheritance ─────────────────────────────────────────────────────────
# Save the engineer from re-authenticating in a new profile. Two parts:
#   1. .claude.json onboarding metadata — without oauthAccount + onboarding flags,
#      the REPL runs /login-onboarding on EVERY launch. Seed it from the engineer's
#      OWN existing .claude.json (their account metadata, no secrets, same machine).
#   2. Credentials — env-var token covers all profiles; .credentials.json is
#      copyable; macOS Keychain is per-profile (one-time /login, or use the token).
# Only account metadata + onboarding/terminal-setup flags — never tokens, projects,
# history, or usage counters.
CLAUDE_JSON_SEED_FILTER='{oauthAccount, hasCompletedOnboarding, lastOnboardingVersion, deepLinkTerminal, optionAsMetaKeyInstalled, appleTerminalSetupInProgress, autoPermissionsNotificationCount} | with_entries(select(.value != null))'

seed_auth() {
  local config_dir="$1" alias_name="$2"
  local target="$config_dir/.claude.json"

  # 1. onboarding metadata
  if [ -f "$target" ] && grep -q '"oauthAccount"' "$target" 2>/dev/null; then
    ok "$(basename "$config_dir")/.claude.json already has oauthAccount — no onboarding needed"
  else
    local src=""
    for c in "$HOME/.claude.json" "$HOME/.claude/.claude.json"; do
      [ -f "$c" ] && grep -q '"oauthAccount"' "$c" 2>/dev/null && { src="$c"; break; }
    done
    if [ -n "$src" ]; then
      local seed existing='{}'
      seed="$(jq "$CLAUDE_JSON_SEED_FILTER" "$src")"
      [ -f "$target" ] && existing="$(cat "$target")"
      jq -s '.[0] * .[1]' <(printf '%s' "$existing") <(printf '%s' "$seed") > "$target.tmp" && mv "$target.tmp" "$target"
      chmod 600 "$target"
      ok "Seeded .claude.json from ${src/#$HOME/~} — skips first-launch onboarding"
    else
      warn "No existing .claude.json with oauthAccount found — first launch will onboard once."
    fi
  fi

  # 2. detect the ACTIVE auth method (Claude Code's precedence order) and inherit
  #    it where that's possible:
  #      env tokens        → cover every CLAUDE_CONFIG_DIR automatically; no copy
  #      .credentials.json → file-based (Linux); copyable
  #      macOS Keychain    → keyed per config dir; CANNOT migrate between configs,
  #                          so the new alias must re-authenticate once.
  local src_creds="$HOME/.claude/.credentials.json"
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    ok "Auth detected: ANTHROPIC_API_KEY (env) — covers every profile, no copy needed."
  elif [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
    ok "Auth detected: ANTHROPIC_AUTH_TOKEN (env) — covers every profile, no copy needed."
  elif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    ok "Auth detected: CLAUDE_CODE_OAUTH_TOKEN (env setup-token) — covers every profile, no re-login."
  elif [ "$(uname)" != "Darwin" ] && [ -f "$src_creds" ]; then
    cp "$src_creds" "$config_dir/.credentials.json"; chmod 600 "$config_dir/.credentials.json"
    ok "Auth detected: credentials.json (file) — copied into the new profile, no re-login."
  else
    warn "You'll need to authenticate once when you first launch '${alias_name}'."
    say  "  ${C_DIM}Keychain/OAuth login can't migrate between Claude configs — Claude Code keys it per config dir.${C_RST}"
    say  "  ${C_DIM}Tip: 'claude setup-token' → export CLAUDE_CODE_OAUTH_TOKEN covers ALL profiles with no per-profile login.${C_RST}"
  fi
}

# ── migrate from existing config ─────────────────────────────────────────────
# Rewrite hook/statusLine command paths in a settings.json from the OLD config
# dir to the new one, so migrated registrations resolve under CLAUDE_CONFIG_DIR.
# stdin: settings json → stdout: rewritten json.
rewrite_hook_paths() {
  local new_hooks="$1/hooks" abs="$HOME/.claude/hooks"
  # Repoint hook/statusLine commands that live under ANY sibling claude-config
  # hooks dir ($HOME/.claudeXXX/hooks — covers migrating from a non-default
  # profile like .claude-clean) at THIS profile's hooks dir, so migrated
  # registrations resolve inside the new config instead of dangling at the source.
  jq --arg abs "$abs" --arg new "$new_hooks" '
    def fix:
      if type=="string" then
        if test("^\\$HOME/\\.claude[^/]*/hooks") then sub("^\\$HOME/\\.claude[^/]*/hooks"; $new)
        elif startswith($abs) then $new + ltrimstr($abs)
        else . end
      else . end;
    walk(if type=="object" and has("command") then .command |= fix else . end)
  '
}

# Scan one category of the source config, list items, let the user pick, copy
# the selected ones into the new profile.
#   migrate_category <src_root> <config_dir> <category> <file|dir>
migrate_category() {
  local src="$1/$3" dst="$2/$3" cat="$3" kind="$4" items=() it
  [ -d "$src" ] || return 0
  if [ "$kind" = "dir" ]; then
    for it in "$src"/*/; do [ -d "$it" ] && items+=("$(basename "$it")"); done
  else
    for it in "$src"/*; do [ -f "$it" ] && items+=("$(basename "$it")"); done
  fi
  [ ${#items[@]} -eq 0 ] && return 0

  say ""
  say "  ${C_BOLD}${cat}${C_RST} ${C_DIM}(${#items[@]} in ${1/#$HOME/~})${C_RST}"
  local i=1
  for it in "${items[@]}"; do say "    ${C_DIM}${i})${C_RST} ${it%.md}"; i=$((i+1)); done
  local sel; prompt sel "    migrate which? (e.g. 1 3, 1-3, 'all', Enter=none):" ""
  local idxs; idxs="$(parse_selection "$sel" "${#items[@]}")"
  [ -z "$idxs" ] && { say "    ${C_DIM}skipped${C_RST}"; return 0; }

  mkdir -p "$dst"
  local n=0 idx
  for idx in $idxs; do
    it="${items[$((idx-1))]}"
    # -L dereferences symlinks so migrated items are SELF-CONTAINED real files in
    # the new profile. Without it a symlinked source hook (common when hooks are
    # symlinked from a shared dir) lands as a link pointing outside the profile —
    # and a later addition cp would then write THROUGH it, clobbering the link's
    # target. See place_file.
    if cp -RL "$src/$it" "$dst/"; then
      [ "$cat" = "hooks" ] && chmod +x "$dst/$it" 2>/dev/null || true
      n=$((n+1))
    fi
  done
  ok "Migrated $n ${cat} → ${dst/#$HOME/~}"
}

setup_one_config() {
  hr
  # 1. target config dir (the default ~/.claude is a valid target — see 1b)
  local config_dir
  isay "${C_DIM}Tip: enter ~/.claude to back up and rebuild your DEFAULT config with these additions.${C_RST}"
  prompt config_dir "Config folder to create/update:" "$HOME/.claude-aka"
  config_dir="${config_dir/#\~/$HOME}"

  # 1b. in-place rebuild: when the target config dir ALREADY EXISTS, offer to move
  # it to a timestamped backup, recreate it clean with the selected additions, and
  # migrate the engineer's picks back from the backup. Works for ANY config dir —
  # a clean upgrade/reinstall path, not just ~/.claude (the default dir is a
  # special case below: no alias, since plain `claude` launches it). Decline →
  # layer the additions on top in place instead.
  local is_default=0 rebuild_backup=""
  # Migration SOURCE defaults to the LIVE Claude Code config dir — wherever CC
  # reads config from right now ($CLAUDE_CONFIG_DIR, else ~/.claude) — NOT a
  # hardcoded ~/.claude. The engineer can point it at any other folder or a
  # backup at the migrate prompt below.
  local default_src="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  [ "$config_dir" = "$HOME/.claude" ] && is_default=1
  if [ -d "$config_dir" ]; then
    local _disp="${config_dir/#$HOME/~}" _rebuild_def="N"
    # Default to rebuild only for the canonical default config; for any other
    # existing profile default to layer-in-place so an idempotent re-run (add an
    # addition) never surprises you by wiping the dir. --clean opts into the
    # rebuild explicitly (state is restored from the backup either way).
    [ "$is_default" = "1" ] && _rebuild_def="Y"
    [ "$CT_CLEAN" = "1" ] && _rebuild_def="Y"
    say ""
    if [ "$is_default" = "1" ]; then
      warn "Target is your DEFAULT Claude config (~/.claude)."
    else
      warn "Target ${_disp} already exists."
    fi
    say  "  ${C_DIM}Back up + rebuild: ${_disp} is moved to a timestamped backup and recreated clean"
    say  "  with the current kit files. Already running aka-claude-tools here? This IS the upgrade"
    say  "  path — it refreshes the additions to this version with no cruft.${C_RST}"
    say  "  ${C_DIM}Not a fresh install: your conversations, memory/, prompt history, todos, CLAUDE.md"
    say  "  and settings.json are restored automatically from the backup. Only user-added agents/"
    say  "  skills/commands/hooks are an explicit pick below.${C_RST}"
    say  "  ${C_DIM}Your login survives: account metadata + a file-based .credentials.json are restored"
    say  "  from the backup, and Keychain auth is keyed to the unchanged dir path.${C_RST}"
    say  "  ${C_DIM}A running Claude Code session keeps working — it's already loaded in memory —"
    say  "  but it may show hook errors while files are being changed underneath it. That's"
    say  "  normal and won't impact the install. The next launch loads the new setup.${C_RST}"
    if confirm "Back up ${_disp} and rebuild it clean?" "$_rebuild_def"; then
      rebuild_backup="${config_dir}.backup-$(date +%Y%m%d-%H%M%S)"
      # Arm the rollback trap BEFORE the mv: from here until the rebuild finishes,
      # an interrupt or failure restores the backup over the half-built dir.
      _CT_REBUILD_TARGET="$config_dir"
      _CT_REBUILD_BACKUP="$rebuild_backup"
      _CT_REBUILD_DONE=0
      mv "$config_dir" "$rebuild_backup"
      mkdir -p "$config_dir"
      default_src="$rebuild_backup"
      ok "Backed up ${_disp} → ${rebuild_backup/#$HOME/~}"
      # State that must survive a clean rebuild without a re-login. For the DEFAULT
      # dir, ~/.claude.json (oauthAccount + onboarding) lives at $HOME and is
      # untouched; for any OTHER dir that metadata lived inside it, so restore the
      # onboarding fields + a file-based .credentials.json from the backup. macOS
      # Keychain auth is keyed to the (unchanged) dir path either way.
      if [ -f "$rebuild_backup/.claude.json" ] && grep -q '"oauthAccount"' "$rebuild_backup/.claude.json" 2>/dev/null; then
        jq "$CLAUDE_JSON_SEED_FILTER" "$rebuild_backup/.claude.json" > "$config_dir/.claude.json" 2>/dev/null \
          && chmod 600 "$config_dir/.claude.json" && ok "Restored onboarding metadata from the backup"
      fi
      if [ -f "$rebuild_backup/.credentials.json" ]; then
        cp "$rebuild_backup/.credentials.json" "$config_dir/.credentials.json"
        chmod 600 "$config_dir/.credentials.json"
        ok "Restored .credentials.json — no re-login"
      fi
      if [ -f "$rebuild_backup/aka-claude-tools.config" ]; then
        cp "$rebuild_backup/aka-claude-tools.config" "$config_dir/aka-claude-tools.config"
        ok "Restored aka-claude-tools.config"
      fi
      # The profile's OWN data — restored automatically so a clean rebuild is an
      # upgrade, not a fresh install. This is the dir's own state coming back
      # (not a cross-config migration), so it is unconditional, not prompted.
      #   • settings.json  — restored first so the build MERGES the current kit
      #     settings onto the user's (reconciling retired rules), instead of
      #     starting from empty. Same dir → hook paths are unchanged, no rewrite.
      #   • CLAUDE.md      — user-authored global memory/imports, not kit content.
      #   • session state  — conversations, memory/, prompt history, todos, tasks
      #     (migrate_sessions / CT_SESSION_ITEMS). Secret-bearing caches
      #     (shell-snapshots, paste-cache, file-history, session-env) stay in the
      #     backup by design; .credentials.json was already restored above.
      if [ -f "$rebuild_backup/settings.json" ]; then
        cp "$rebuild_backup/settings.json" "$config_dir/settings.json"
        ok "Restored settings.json (reconciled with this version's kit settings below)"
      fi
      if [ -f "$rebuild_backup/CLAUDE.md" ]; then
        cp "$rebuild_backup/CLAUDE.md" "$config_dir/CLAUDE.md"
        ok "Restored CLAUDE.md ($(wc -l < "$config_dir/CLAUDE.md" | tr -d ' ') lines)"
      fi
      migrate_sessions "$rebuild_backup" "$config_dir"
      # Transparency: report exactly what runtime state came back. An upgrade
      # should be auditable — the kit's "never change things silently" principle
      # applies to restores too. Counts are best-effort and portable (BSD/GNU).
      if [ -d "$config_dir/projects" ]; then
        local _nmem _nconv
        _nmem="$(find "$config_dir/projects" -type d -name memory 2>/dev/null | wc -l | tr -d ' ')"
        _nconv="$(find "$config_dir/projects" -type f -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')"
        ok "Restored runtime state: ${_nmem} memory dir(s), ${_nconv} conversation(s)"
      fi
    else
      say "  ${C_DIM}No backup — layering additions onto ${_disp} in place instead.${C_RST}"
    fi
  fi

  # 2. alias name (default derived from folder basename: ~/.claude-aka -> aka).
  # Skipped for the default dir — plain `claude` already launches it.
  local alias_name=""
  if [ "$is_default" != "1" ]; then
    local base alias_default
    base="$(basename "$config_dir")"
    alias_default="${base#.claude-}"; [ "$alias_default" = "$base" ] && alias_default="aka"
    [ -z "$alias_default" ] && alias_default="aka"
    prompt alias_name "Shell alias to launch it:" "$alias_default"
  fi

  # 3. migrate from an existing config — scan each category, pick what to bring
  # over. Default source = the LIVE CC config dir derived above (or the backup
  # when rebuilding); the engineer can type any other folder, or decline.
  local mig_def="N" migrate_src=""
  [ -n "$rebuild_backup" ] && mig_def="Y"
  isay ""
  if confirm "Migrate items from an existing Claude config into this profile?" "$mig_def"; then
    prompt migrate_src "  Migrate FROM which config folder?" "$default_src"
    migrate_src="${migrate_src/#\~/$HOME}"
    [ -d "$migrate_src" ] || { warn "No such folder: ${migrate_src/#$HOME/~} — skipping migration."; migrate_src=""; }
    [ -n "$migrate_src" ] && [ "$migrate_src" = "$config_dir" ] && { warn "Source is this profile itself — skipping migration."; migrate_src=""; }
    if [ -n "$migrate_src" ]; then
      mkdir -p "$config_dir"
      ok "Migrating from ${migrate_src/#$HOME/~}"
      # In the rebuild path the source IS this profile's own backup, and its
      # settings.json, CLAUDE.md, and session history were already restored
      # automatically above. Skip those prompts and offer only the items the
      # auto-restore deliberately leaves to a choice (agents, skills, commands,
      # output-styles, user hooks).
      [ "$migrate_src" = "$rebuild_backup" ] && isay "  ${C_DIM}settings.json, CLAUDE.md & session history already restored from the backup — pick any extra agents/skills/commands/hooks to bring back.${C_RST}"
      if [ "$migrate_src" != "$rebuild_backup" ] && [ -f "$migrate_src/settings.json" ] && confirm "  • merge your existing settings.json (hook paths auto-rewritten)?" "Y"; then
        rewrite_hook_paths "$config_dir" < "$migrate_src/settings.json" > "$config_dir/settings.json.mig"
        # Dangerous-mode settings are the user's call, not ours: if their config
        # already runs with bypassPermissions / skip-prompt flags, surface it and
        # offer to turn it off — but KEEP their setting by default. The kit's own
        # template never adds these; this only honors what the user already had.
        if jq -e '(.permissions.defaultMode == "bypassPermissions") or (.skipDangerousModePermissionPrompt == true) or (.skipAutoPermissionPrompt == true)' "$config_dir/settings.json.mig" >/dev/null 2>&1; then
          isay "    ${C_DIM}Heads-up: your settings enable bypassPermissions and/or the skip-prompt flags,${C_RST}"
          isay "    ${C_DIM}so Claude runs without permission prompts by default in this profile.${C_RST}"
          if confirm "  • keep bypassPermissions / skip-prompt flags as you had them?" "Y"; then
            ok "Kept your bypassPermissions / skip-prompt settings as-is."
          else
            jq '(if .permissions.defaultMode == "bypassPermissions" then .permissions |= del(.defaultMode) else . end)
                | del(.skipDangerousModePermissionPrompt, .skipAutoPermissionPrompt)' \
              "$config_dir/settings.json.mig" > "$config_dir/settings.json.mig.tmp" \
              && mv "$config_dir/settings.json.mig.tmp" "$config_dir/settings.json.mig"
            ok "Turned off bypassPermissions / skip-prompt flags for this profile."
          fi
        fi
        mv "$config_dir/settings.json.mig" "$config_dir/settings.json"
        ok "Staged your settings.json → this profile (hook paths rewritten)"
      fi
      if [ "$migrate_src" != "$rebuild_backup" ] && [ -f "$migrate_src/CLAUDE.md" ] && confirm "  • copy your CLAUDE.md?" "N"; then
        cp "$migrate_src/CLAUDE.md" "$config_dir/CLAUDE.md"; ok "Copied CLAUDE.md"
      fi
      migrate_category "$migrate_src" "$config_dir" agents        file
      migrate_category "$migrate_src" "$config_dir" skills        dir
      migrate_category "$migrate_src" "$config_dir" commands      file
      migrate_category "$migrate_src" "$config_dir" output-styles file
      migrate_category "$migrate_src" "$config_dir" hooks         file
      migrate_category "$migrate_src" "$config_dir" workflows     file
      # Optional: bring over session/history state (past conversations, input
      # history, todos) from ANOTHER config. OFF by default — it's personal and
      # can be large, and secrets / shell-env / paste caches are never included
      # (see migrate_sessions in common.sh). Skipped when the source is this
      # profile's own rebuild backup — that state was already restored above.
      if [ "$migrate_src" != "$rebuild_backup" ]; then
        isay ""
        if confirm "  • also migrate session history (past conversations, input history, todos)?" "N"; then
          migrate_sessions "$migrate_src" "$config_dir"
        fi
      fi
    fi
  fi

  # 4. select additions — the menu (which additions exist, their order, prompt
  # text, and default) is driven ENTIRELY by config/additions.json so Path B
  # (this script) and Path A (agent-install.md) can't drift. Each addition's
  # bespoke build logic below is keyed on its id via is_selected.
  isay ""
  isay "Additions to layer on ${C_DIM}(Enter = default):${C_RST}"
  local _sel_ids=" " _aid _arec _aprompt _adef
  while IFS=$'\t' read -r _aid _arec _aprompt; do
    [ -z "$_aid" ] && continue
    if [ "$_arec" = "true" ]; then _adef="Y"; else _adef="N"; fi
    if confirm "  • ${_aprompt}" "$_adef"; then _sel_ids="${_sel_ids}${_aid} "; fi
  done < <(jq -r '.additions[] | [.id, (.recommended|tostring), (.prompt // .name)] | @tsv' "$CONFIG_SRC/additions.json")

  # ── build ──
  mkdir -p "$config_dir/hooks" "$config_dir/commands" "$config_dir/workflows"

  # 4b. assemble additions object
  local add='{}'
  is_selected secure-settings "$_sel_ids" && add="$(jq -s '.[0] * .[1]' <(printf '%s' "$add") "$CONFIG_SRC/settings.base.json")"

  # Shared library the egress guards read (single source of truth for the
  # secret/outbound patterns). Placed whenever either guard is selected, so both
  # bash and TS resolve config/hooks/lib/secret-patterns.json relative to themselves.
  if is_selected leak-guard "$_sel_ids" || is_selected command-guard "$_sel_ids"; then
    place_dir "$CONFIG_SRC/hooks/lib" "$config_dir/hooks"
  fi

  if is_selected leak-guard "$_sel_ids"; then
    place_file "$CONFIG_SRC/hooks/leak-guard.sh" "$config_dir/hooks" +x
    # Registered twice: web tools (always scanned) and Bash (fast-gated — only
    # commands containing an outbound tool are scanned; ~98% of calls pay ~0 ms).
    add="$(jq --arg cmd "$config_dir/hooks/leak-guard.sh" \
      '.hooks.PreToolUse += [{matcher:"WebSearch|WebFetch",hooks:[{type:"command",command:$cmd}]},
                             {matcher:"Bash",hooks:[{type:"command",command:$cmd}]}]' <<<"$add")"
    # Optional: stronger secret detection. Degrades to regex tiers without it.
    ensure_dep trufflehog "trufflehog (web-egress secret detection)" 0 || true
  fi
  if is_selected harness-pointer "$_sel_ids"; then
    place_file "$CONFIG_SRC/hooks/harness-pointer.sh" "$config_dir/hooks" +x
    add="$(jq --arg cmd "$config_dir/hooks/harness-pointer.sh" \
      '.hooks.PreToolUse += [{matcher:"Bash",hooks:[{type:"command",command:$cmd}]}]' <<<"$add")"
  fi
  if is_selected command-guard "$_sel_ids"; then
    # bun is the runtime for command-guard, so it is a hard dependency of THIS addition.
    # Selecting command-guard offers to install bun (interactive, default yes). If it
    # ends up absent (declined / no package manager / non-interactive), command-guard
    # is NOT registered and we say so LOUDLY — a security guard quietly skipped is
    # worse than a noisy one. The leak-guard floor still enforces secret content +
    # pipe-to-shell; what's lost is command-guard's precise key+outbound-tool pairing.
    ensure_dep bun "bun — runtime required by the command-guard egress hook" 0 || true
    local bun_bin; bun_bin="$(command -v bun 2>/dev/null || true)"
    if [ -n "$bun_bin" ]; then
      place_file "$CONFIG_SRC/hooks/command-guard.ts" "$config_dir/hooks" +x
      # Register with bun's ABSOLUTE path. Claude Code runs hooks in a shell that
      # may not have bun on PATH (non-interactive subshells); a bare shebang would
      # silently fail to launch and the guard would be a no-op.
      add="$(jq --arg cmd "$bun_bin $config_dir/hooks/command-guard.ts" \
        '.hooks.PreToolUse += [{matcher:"Bash",hooks:[{type:"command",command:$cmd}]}]' <<<"$add")"
      ok "command-guard enabled (bun: $bun_bin)"
    else
      warn "⚠ command-guard NOT enabled — its runtime 'bun' is missing, so the enhanced Bash"
      warn "  credential-exfil guard will not run. The leak-guard floor still covers secret"
      warn "  content + pipe-to-shell; install bun (https://bun.sh/install) and re-run to add"
      warn "  command-guard's precise key+outbound-tool detection."
    fi
  fi
  if is_selected rtk-safe "$_sel_ids"; then
    ensure_dep rtk "rtk (RTK rewriting)" 0 || true
    # rtk-safe self-skips at runtime if rtk/jq are absent, so it's safe to register unconditionally.
    place_file "$CONFIG_SRC/hooks/rtk-safe.sh" "$config_dir/hooks" +x
    add="$(jq --arg cmd "$config_dir/hooks/rtk-safe.sh" \
      '.hooks.PreToolUse += [{matcher:"Bash",hooks:[{type:"command",command:$cmd}]}]' <<<"$add")"
    # Read-only rtk allowlist: the rewrite changes the command string, so the
    # user's existing allow rules (e.g. Bash(git status:*)) no longer match the
    # rewritten form. Allow ONLY the strictly read-only rtk forms to keep prompt
    # friction where it was; mutating/egress forms (rtk curl, rtk aws, rtk git
    # push, …) keep prompting. Deliberately NOT a blanket Bash(rtk:*) — rtk
    # fronts curl/aws/psql/docker, so that would amount to a general Bash allow.
    add="$(jq -s '.[0] * .[1]' <(printf '%s' "$add") "$CONFIG_SRC/rtk-allowlist.json")"
    command -v rtk >/dev/null 2>&1 || warn "RTK rewriting registered but inert until 'rtk' is installed."
  fi
  if is_selected statusline "$_sel_ids"; then
    place_file "$CONFIG_SRC/hooks/statusline.sh" "$config_dir/hooks" +x
    add="$(jq --arg cmd "$config_dir/hooks/statusline.sh" \
      '.statusLine = {type:"command",command:$cmd,refreshInterval:2}' <<<"$add")"
    # Optional location pin for accurate weather (default: auto-detect by IP).
    isay ""
    isay "  ${C_DIM}Statusline weather uses your location — default is auto-detect by IP (city-level).${C_RST}"
    isay "  ${C_DIM}You can pin an exact spot instead. Nothing is saved or collected by aka-claude-tools:${C_RST}"
    isay "  ${C_DIM}your entry is geocoded once via OpenStreetMap, only the resulting coordinates are${C_RST}"
    isay "  ${C_DIM}stored — locally, in this profile's settings.json — and the text itself is not kept.${C_RST}"
    local _loc_in; prompt _loc_in "  Pin a location? city or address (Enter = auto/IP):" ""
    if [ -n "$_loc_in" ]; then
      local _q _geo _plat _plon _pcc _prc _pdisp
      _q=$(jq -rn --arg q "$_loc_in" '$q|@uri')
      _geo=$(curl -s --max-time 8 -H "User-Agent: aka-claude-tools-installer" \
        "https://nominatim.openstreetmap.org/search?q=${_q}&format=jsonv2&limit=1&addressdetails=1" 2>/dev/null)
      _plat=$(printf '%s' "$_geo" | jq -r '.[0].lat // empty' 2>/dev/null)
      _plon=$(printf '%s' "$_geo" | jq -r '.[0].lon // empty' 2>/dev/null)
      _pcc=$(printf '%s' "$_geo" | jq -r '(.[0].address.country_code // "") | ascii_upcase' 2>/dev/null)
      # Abbreviated state/region (ISO3166-2 "US-CA" → "CA") — the statusline shows
      # this instead of a city name.
      _prc=$(printf '%s' "$_geo" | jq -r '(.[0].address["ISO3166-2-lvl4"] // "" | split("-") | last) // empty' 2>/dev/null)
      _pdisp=$(printf '%s' "$_geo" | jq -r '.[0].display_name // empty' 2>/dev/null)
      # Validate before --argjson: a malformed geocoder response must not abort
      # the installer under set -e.
      [[ "$_plat" =~ ^-?[0-9]+(\.[0-9]+)?$ && "$_plon" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || { _plat=""; _plon=""; }
      if [ -n "$_plat" ] && [ -n "$_plon" ]; then
        if confirm "  Pin \"${_pdisp}\" (${_plat}, ${_plon})?" "Y"; then
          add="$(jq --argjson la "$_plat" --argjson lo "$_plon" --arg cc "$_pcc" --arg rc "$_prc" \
            '.preferences.location = {latitude:$la, longitude:$lo, countryCode:$cc, regionCode:$rc}' <<<"$add")"
          ok "Pinned location → this profile (coordinates only)."
        fi
      else
        warn "Couldn't geocode \"${_loc_in}\" — using IP auto-detect instead."
      fi
    fi
  fi
  if is_selected wrap-up "$_sel_ids"; then
    place_file "$CONFIG_SRC/commands/wrap-up.md" "$config_dir/commands"
  fi
  if is_selected shell-audit "$_sel_ids"; then
    place_dir "$CONFIG_SRC/skills/shell-audit" "$config_dir/skills"
    chmod +x "$config_dir/skills/shell-audit/audit.sh" 2>/dev/null || true
    ok "Placed shell-audit skill"
  fi
  if is_selected startup-write-guard "$_sel_ids"; then
    place_file "$CONFIG_SRC/hooks/startup-write-guard.sh" "$config_dir/hooks" +x
    add="$(jq --arg cmd "$config_dir/hooks/startup-write-guard.sh" \
      '.hooks.PreToolUse += [{matcher:"Bash",hooks:[{type:"command",command:$cmd}]}]' <<<"$add")"
  fi
  if is_selected secure-deep-research "$_sel_ids"; then
    # A .js dropped in <config>/workflows/ auto-registers as BOTH the named
    # workflow and the /secure-deep-research skill (Claude Code scans this dir).
    place_file "$CONFIG_SRC/workflows/secure-deep-research.js" "$config_dir/workflows"
    ok "Placed secure-deep-research workflow ${C_DIM}(invoke: /secure-deep-research)${C_RST}"
  fi

  # 4c. opt-in config template if any config-driven hook was selected
  if { is_selected leak-guard "$_sel_ids" || is_selected harness-pointer "$_sel_ids"; } && [ ! -f "$config_dir/aka-claude-tools.config" ]; then
    cp "$REPO_DIR/shared/aka-claude-tools.config.example" "$config_dir/aka-claude-tools.config"
    ok "Placed aka-claude-tools.config (opt-in, empty by default)"
  fi

  # 4d. merge settings (existing-in-dir ∪ additions) and write
  local existing='{}'
  [ -f "$config_dir/settings.json" ] && existing="$(cat "$config_dir/settings.json")"

  # 4d-pre. Uninstall deselected additions. Unchecking an addition you had
  # before now REMOVES it: its hook/command/skill files are deleted and its
  # settings contributions (hook registrations, statusLine, shipped permission/
  # env rules) are pruned from `existing` before the merge re-adds the selected
  # ones. Driven by config/additions.json; idempotent (no-op for anything not
  # actually present), so it's safe to run for every unselected id.
  local _uid _p _changed
  for _uid in $(jq -r '.additions[].id' "$CONFIG_SRC/additions.json"); do
    is_selected "$_uid" "$_sel_ids" && continue
    _changed=0
    while IFS= read -r _p; do
      [ -n "$_p" ] && [ -e "$_p" ] && { rm -rf "$_p"; _changed=1; }
    done < <(addition_owned_paths "$_uid" "$config_dir")
    if [ "$existing" != "{}" ]; then
      local _pruned; _pruned="$(printf '%s' "$existing" | prune_addition_from_settings "$_uid")"
      [ -n "$_pruned" ] && [ "$_pruned" != "$existing" ] && { existing="$_pruned"; _changed=1; }
    fi
    [ "$_changed" = "1" ] && ok "Uninstalled '${_uid}' — removed its files and settings entries"
  done

  # 4d-pre1b. Clean RETIRED additions — whole additions the kit shipped before and
  # has since dropped from additions.json. The loop above only iterates ids STILL
  # in the manifest, so a fully-removed addition's files would orphan in an existing
  # profile; config/managed-permissions.json (.retiredAdditions[].paths) tombstones
  # their owned paths. Skills/commands only (idempotent rm); retired HOOKS self-clean
  # via the managed marker in 4d-pre2 below.
  while IFS= read -r _rp; do
    [ -n "$_rp" ] || continue
    [ -e "$config_dir/$_rp" ] && { rm -rf "$config_dir/$_rp"; ok "Removed retired addition file: ${_rp}"; }
  done < <(jq -r '.retiredAdditions // [] | .[] | .paths[]?' "$CONFIG_SRC/managed-permissions.json" 2>/dev/null)

  # 4d-pre2. Self-clean stale kit hooks. Every shipped hook carries a managed
  # marker (aka-claude-tools:managed-hook). Any marked hook in the profile that
  # the kit NO LONGER ships — i.e. one it renamed or retired — is removed and its
  # registration pruned. Marker-based, so it needs no maintained list and never
  # touches the user's own (unmarked) hooks. (Profiles from before the marker
  # existed carry unmarked old hooks; those are handled by a one-time migration,
  # not here.)
  if [ -d "$config_dir/hooks" ]; then
    local _hf _hb
    for _hf in "$config_dir"/hooks/*; do
      [ -e "$_hf" ] || continue
      grep -q 'aka-claude-tools:managed-hook' "$_hf" 2>/dev/null || continue   # not ours → leave it
      _hb="$(basename "$_hf")"
      [ -e "$CONFIG_SRC/hooks/$_hb" ] && continue                              # still shipped → keep
      rm -f "$_hf"
      [ "$existing" != "{}" ] && existing="$(printf '%s' "$existing" | prune_hook_regs "$_hb")"
      ok "Removed renamed/retired kit hook '$_hb' (managed-marker)"
    done
  fi

  # Reconcile kit-managed permission rules first: a plain merge only UNIONS, so it
  # can add new denies/allows but never drop ones the kit has retired. This shows
  # the engineer the per-rule diff and lets them choose (default: adopt this
  # version's set), without ever touching rules they added themselves.
  reconcile_managed_perms "$existing" "$add"
  existing="$RECON_EXISTING"; add="$RECON_ADD"
  if [ "$add" != "{}" ] || [ "$existing" != "{}" ]; then
    merge_settings "$existing" "$add" > "$config_dir/settings.json.tmp"
    mv "$config_dir/settings.json.tmp" "$config_dir/settings.json"
    ok "Wrote $config_dir/settings.json"
  fi

  # tidy empty dirs
  rmdir "$config_dir/hooks" "$config_dir/commands" "$config_dir/workflows" 2>/dev/null || true

  # 4e. inherit auth so the engineer doesn't re-onboard / re-login.
  # The default profile needs neither: its ~/.claude.json lives at $HOME (not in
  # the config dir) and its Keychain/credentials were preserved in step 1b.
  if [ "$SEED_AUTH" = "1" ] && [ "$is_default" != "1" ]; then
    seed_auth "$config_dir" "$alias_name"
  fi

  # 5. write alias to shell rc (the default dir needs none — plain `claude`)
  if [ "$is_default" = "1" ]; then
    say ""
    ok "Default config ~/.claude ready — plain ${C_BOLD}claude${C_RST} launches it."
    [ -n "$rebuild_backup" ] && say "  ${C_DIM}Your conversations, memory, history & settings were restored. Backup kept at ${rebuild_backup/#$HOME/~} as a safety net (also holds excluded caches: shell-snapshots, paste-cache, file-history) — delete it once you're happy.${C_RST}"
    say "  ${C_DIM}Restart claude to load the rebuilt config — a running session keeps the old one in memory.${C_RST}"
  else
    local rc; rc="$(detect_shell_rc)"
    # Review existing aliases before inserting ours — check the rc and every file
    # reachable through its `source` chain (fully recursive, cycle-safe), so we
    # never silently duplicate or shadow an alias the user already has (e.g. one a
    # fleet-wide aliases file provides). See alias_target_elsewhere in common.sh;
    # the agent-install path does the same review and adds judgment on edge cases.
    local prior; prior="$(alias_target_elsewhere "$alias_name" "$rc")"
    if [ "$prior" = "$config_dir" ]; then
      # Already resolves to THIS profile from elsewhere → don't add a duplicate;
      # drop any stale managed block of ours so there's a single definition.
      if remove_managed_block "$rc" "$alias_name"; then
        ok "Alias ${C_BOLD}${alias_name}${C_RST} already resolves to this profile via your shell config — removed our now-redundant block."
      else
        ok "Alias ${C_BOLD}${alias_name}${C_RST} already resolves to this profile via your shell config — not adding a duplicate."
      fi
    elif [ -n "$prior" ]; then
      if [ "$prior" = "OTHER" ]; then
        warn "'${alias_name}' is already an alias in your shell (not a Claude-config launcher)."
      else
        warn "Alias '${alias_name}' already exists and points to: ${prior}"
        say  "  ${C_DIM}(from your shell rc or a file it sources — not this profile).${C_RST}"
      fi
      local newalias=""
      prompt newalias "  Use a different alias (blank = skip the alias entirely):" "${alias_name}2"
      if [ -n "$newalias" ]; then
        write_managed_block "$rc" "$newalias" \
"alias ${newalias}='CLAUDE_CONFIG_DIR=\"${config_dir}\" claude'"
        alias_name="$newalias"
        ok "Aliased ${C_BOLD}${alias_name}${C_RST} → $config_dir  ${C_DIM}(in $rc)${C_RST}"
      else
        say "  ${C_DIM}No alias written. Launch this profile with:${C_RST}  CLAUDE_CONFIG_DIR=\"${config_dir}\" claude"
      fi
    else
      write_managed_block "$rc" "$alias_name" \
"alias ${alias_name}='CLAUDE_CONFIG_DIR=\"${config_dir}\" claude'"
      ok "Aliased ${C_BOLD}${alias_name}${C_RST} → $config_dir  ${C_DIM}(in $rc)${C_RST}"
    fi

    say ""
    ok "Config '${alias_name}' ready."
    [ -n "$rebuild_backup" ] && say "  ${C_DIM}Your conversations, memory, history & settings were restored. Backup kept at ${rebuild_backup/#$HOME/~} as a safety net (also holds excluded caches: shell-snapshots, paste-cache, file-history) — delete it once you're happy.${C_RST}"
    say "  ${C_DIM}Open a new shell (or: source $rc), then run:${C_RST}  ${C_BOLD}${alias_name}${C_RST}"
  fi

  # Rebuild finished cleanly — disarm the rollback trap for this config.
  # (Must use `if`, not `&&`: a bare test that's false would make this the
  # function's non-zero return and trip `set -e` in the caller.)
  if [ -n "$rebuild_backup" ]; then _CT_REBUILD_DONE=1; fi
}

# ── main loop ────────────────────────────────────────────────────────────────
setup_one_config
while confirm "Set up another config folder?" "N"; do
  setup_one_config
done

say ""
hr
ok "Done. ${C_DIM}Re-run ./install.sh any time to add or update a config.${C_RST}"
