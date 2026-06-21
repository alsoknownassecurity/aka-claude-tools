#!/usr/bin/env bash
# Scenario T13 — INSTALL/edge: auth inheritance.
#
# With an existing login present at $HOME (~/.claude.json carrying oauthAccount +
# onboarding flags, the on-disk shape Claude Code writes after /login), the
# DEFAULT install (--defaults, no --no-auth-inherit) seeds the NEW non-default
# profile's .claude.json so the engineer is not re-onboarded on first launch.
# --no-auth-inherit must NOT seed it. And in BOTH cases the seed must carry only
# what avoids re-onboarding/re-login — never the secret/PII payload that lives in
# the source .claude.json (projects, history, usage counters, arbitrary blobs).
#
# Mechanism (install.sh: seed_auth, gated by `SEED_AUTH=1 && is_default!=1`):
#   • --defaults targets ~/.claude-aka (non-default) → seed_auth runs.
#   • seed_auth part 1: filters the source .claude.json through
#     CLAUDE_JSON_SEED_FILTER (oauthAccount + onboarding/terminal flags only) and
#     merges it into the new profile's .claude.json.
#   • seed_auth part 2: on Linux a file-based ~/.claude/.credentials.json is
#     copied in; on macOS (Darwin) Keychain auth can't migrate, so NO credentials
#     file is written and the engineer is told to re-login once (or use a token).
#     This sandbox seeds a .credentials.json and asserts the OS-correct behavior.
#
# Fully sandboxed: fake $HOME, --defaults (non-interactive), throwaway profile.
# Never touches a real ~/.claude*. No env auth tokens are exported here, so the
# auth-method branch is the file/Keychain one (deterministic per-OS).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_install_auth_inherit:"

OS="$(uname)"

# ── a realistic "existing login" fixture: oauthAccount + onboarding flags PLUS a
# payload of things that must NOT be inherited (PII/secret/cruft). ─────────────
seed_existing_login() {
  local home="$1"
  cat > "$home/.claude.json" <<'JSON'
{
  "oauthAccount": {
    "accountUuid": "11111111-2222-3333-4444-555555555555",
    "emailAddress": "engineer@example.com",
    "organizationUuid": "99999999-8888-7777-6666-555555555555"
  },
  "hasCompletedOnboarding": true,
  "lastOnboardingVersion": "1.0.99",
  "deepLinkTerminal": "ghostty",
  "numStartups": 4217,
  "userID": "user-secret-id-should-not-travel",
  "projects": {
    "/Users/secret/work": { "history": ["do not exfiltrate this"] }
  },
  "history": ["sensitive REPL prompt", "another private prompt"],
  "tipsHistory": { "x": 1 },
  "fallbackAvailableWarningThreshold": 0.5,
  "cachedChangelog": "secret internal changelog text"
}
JSON
  # A file-based credential, as Claude Code writes on Linux. On macOS this is a
  # decoy (Keychain is authoritative there) — the installer must not copy it.
  mkdir -p "$home/.claude"
  echo '{"claudeAiOauth":{"accessToken":"sk-SECRET-TOKEN-DO-NOT-COPY"}}' > "$home/.claude/.credentials.json"
}

# ════════════════════════════════════════════════════════════════════════════
# CASE A — DEFAULT install (auth inheritance ON): new profile gets seeded.
# ════════════════════════════════════════════════════════════════════════════
SB_A="$(sandbox)"
seed_existing_login "$SB_A"
outA="$SB_A/install.log"
HOME="$SB_A" bash "$REPO_ROOT/install.sh" --defaults >"$outA" 2>&1
rcA=$?
PA="$SB_A/.claude-aka"
JA="$PA/.claude.json"

assert_eq   "A: install.sh exits 0 (auth inherit default)" "0" "$rcA"
assert_file "A: new profile dir created" "$PA"
assert_file "A: new profile .claude.json was seeded" "$JA"
[ -f "$JA" ] && assert_ok "A: seeded .claude.json is valid JSON" jq -e . "$JA"

# oauthAccount + onboarding flags carried over → no first-launch onboarding.
[ -f "$JA" ] && assert_ok "A: oauthAccount inherited (skips onboarding)" \
  bash -c "jq -e '.oauthAccount.emailAddress == \"engineer@example.com\"' '$JA' >/dev/null"
[ -f "$JA" ] && assert_ok "A: hasCompletedOnboarding inherited" \
  bash -c "jq -e '.hasCompletedOnboarding == true' '$JA' >/dev/null"
[ -f "$JA" ] && assert_ok "A: lastOnboardingVersion inherited" \
  bash -c "jq -e '.lastOnboardingVersion == \"1.0.99\"' '$JA' >/dev/null"
[ -f "$JA" ] && assert_ok "A: deepLinkTerminal inherited" \
  bash -c "jq -e '.deepLinkTerminal == \"ghostty\"' '$JA' >/dev/null"

# Secrets / PII / cruft beyond the onboarding-avoidance set must NOT travel.
[ -f "$JA" ] && assert_ok "A: history NOT copied" \
  bash -c "jq -e 'has(\"history\") | not' '$JA' >/dev/null"
[ -f "$JA" ] && assert_ok "A: projects NOT copied" \
  bash -c "jq -e 'has(\"projects\") | not' '$JA' >/dev/null"
[ -f "$JA" ] && assert_ok "A: userID NOT copied" \
  bash -c "jq -e 'has(\"userID\") | not' '$JA' >/dev/null"
[ -f "$JA" ] && assert_ok "A: numStartups counter NOT copied" \
  bash -c "jq -e 'has(\"numStartups\") | not' '$JA' >/dev/null"
[ -f "$JA" ] && assert_ok "A: cachedChangelog NOT copied" \
  bash -c "jq -e 'has(\"cachedChangelog\") | not' '$JA' >/dev/null"
# Defensive raw-text check: none of the secret values may appear in the file.
assert_nlit "A: secret REPL history text absent from seed" "do not exfiltrate this" "$JA"
assert_nlit "A: secret userID absent from seed"            "user-secret-id-should-not-travel" "$JA"
assert_nlit "A: secret changelog absent from seed"         "secret internal changelog text" "$JA"

# Credentials handling is OS-specific (Keychain on macOS can't migrate).
CA="$PA/.credentials.json"
if [ "$OS" = "Darwin" ]; then
  assert_nlit "A(macOS): credentials.json NOT copied (Keychain can't migrate)" \
    "sk-SECRET-TOKEN-DO-NOT-COPY" "$outA"
  [ -e "$CA" ] && fail "A(macOS): no credentials.json in new profile" "Keychain auth must not be file-copied" \
               || pass "A(macOS): no credentials.json in new profile"
  assert_grep "A(macOS): installer warns a one-time login is needed" \
    "authenticate once|re-login|setup-token" "$outA"
else
  assert_file "A(Linux): credentials.json copied into new profile" "$CA"
  [ -f "$CA" ] && assert_grep "A(Linux): copied credential carries the token" \
    "sk-SECRET-TOKEN-DO-NOT-COPY" "$CA"
  # File-based creds must be locked down 0600 (owner-only).
  if [ -f "$CA" ]; then
    perm="$(stat -f '%Lp' "$CA" 2>/dev/null || stat -c '%a' "$CA" 2>/dev/null)"
    assert_eq "A(Linux): copied credentials.json is mode 600" "600" "$perm"
  fi
fi

# The seeded .claude.json itself must be 0600 (it carries account metadata).
if [ -f "$JA" ]; then
  jperm="$(stat -f '%Lp' "$JA" 2>/dev/null || stat -c '%a' "$JA" 2>/dev/null)"
  assert_eq "A: seeded .claude.json is mode 600" "600" "$jperm"
fi

# The SOURCE login at $HOME must be left untouched (read, not moved/mutated).
assert_file "A: source ~/.claude.json untouched" "$SB_A/.claude.json"
assert_ok   "A: source ~/.claude.json still has its full payload" \
  bash -c "jq -e 'has(\"history\") and has(\"projects\")' '$SB_A/.claude.json' >/dev/null"

# ════════════════════════════════════════════════════════════════════════════
# CASE B — --no-auth-inherit: NOTHING is seeded from the existing login.
# ════════════════════════════════════════════════════════════════════════════
SB_B="$(sandbox)"
seed_existing_login "$SB_B"
outB="$SB_B/install.log"
HOME="$SB_B" bash "$REPO_ROOT/install.sh" --defaults --no-auth-inherit >"$outB" 2>&1
rcB=$?
PB="$SB_B/.claude-aka"
JB="$PB/.claude.json"

assert_eq   "B: install.sh exits 0 (auth inherit off)" "0" "$rcB"
assert_file "B: new profile dir created" "$PB"

# No oauthAccount may be seeded → first launch onboards. The new profile either
# has no .claude.json at all, or one without oauthAccount; either way NO account
# metadata or secret value from the source must appear.
if [ -f "$JB" ]; then
  assert_ok "B: new .claude.json carries NO oauthAccount" \
    bash -c "jq -e 'has(\"oauthAccount\") | not' '$JB' >/dev/null"
  assert_nlit "B: source email NOT seeded" "engineer@example.com" "$JB"
  assert_nlit "B: source history NOT seeded" "do not exfiltrate this" "$JB"
else
  pass "B: new .claude.json carries NO oauthAccount"
  pass "B: source email NOT seeded"
  pass "B: source history NOT seeded"
fi

# No credentials.json copied in the --no-auth-inherit case on any OS.
[ -e "$PB/.credentials.json" ] && fail "B: NO credentials.json copied" "--no-auth-inherit must not copy creds" \
                               || pass "B: NO credentials.json copied"
assert_nlit "B: secret token absent from install log" "sk-SECRET-TOKEN-DO-NOT-COPY" "$outB"

# seed_auth should not even run → none of its "Seeded"/"Auth detected" lines.
assert_nlit "B: installer did not run the seed step" "Seeded .claude.json" "$outB"

t_summary
