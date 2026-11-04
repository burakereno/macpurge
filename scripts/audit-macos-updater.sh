#!/usr/bin/env bash
set -u

ROOT="${1:-$PWD}"

if [[ ! -d "$ROOT" ]]; then
  echo "error: repo path does not exist: $ROOT" >&2
  exit 2
fi

cd "$ROOT" || exit 2

COMMON_GLOBS=(
  --glob '!**/.git/**'
  --glob '!**/.build/**'
  --glob '!**/build/**'
  --glob '!**/DerivedData/**'
  --glob '!**/.claude/worktrees/**'
  --glob '!**/.codex/worktrees/**'
  --glob '!**/docs/**'
  --glob '!**/tests/**'
  --glob '!**/Tests/**'
  --glob '!**/*Tests/**'
  --glob '!*Tests/**'
)

if command -v rg >/dev/null 2>&1; then
  UPDATER_FILES=()
  while IFS= read -r line; do
    UPDATER_FILES+=("$line")
  done < <(
    rg --files --hidden "${COMMON_GLOBS[@]}" --glob '*.swift' \
      | rg '(^|/)(UpdateChecker|UpdateInstaller|UpdateSecurity)[^/]*[.]swift$' \
      | rg -v '(^|/)(Tests|tests|[^/]*Tests)(/|$)'
  )

  updater_search() {
    local pattern="$1"
    if (( ${#UPDATER_FILES[@]} == 0 )); then
      return 0
    fi
    rg -n -- "$pattern" "${UPDATER_FILES[@]}" || true
  }
else
  echo "error: rg is required for scoped updater audit" >&2
  exit 2
fi

issues=0
warnings=0

issue_matches() {
  local title="$1"
  local pattern="$2"
  local matches
  matches="$(updater_search "$pattern")"
  if [[ -n "$matches" ]]; then
    issues=$((issues + 1))
    printf '\n[ISSUE] %s\n%s\n' "$title" "$matches"
  fi
}

warning_matches() {
  local title="$1"
  local pattern="$2"
  local matches
  matches="$(updater_search "$pattern")"
  if [[ -n "$matches" ]]; then
    warnings=$((warnings + 1))
    printf '\n[WARN] %s\n%s\n' "$title" "$matches"
  fi
}

require_pattern() {
  local title="$1"
  local pattern="$2"
  if [[ -z "$(updater_search "$pattern")" ]]; then
    issues=$((issues + 1))
    printf '\n[ISSUE] %s\n' "$title"
  fi
}

echo "Auditing macOS updater patterns in: $(pwd)"

if (( ${#UPDATER_FILES[@]} == 0 )); then
  echo "No updater Swift sources found."
  exit 0
fi

printf 'Updater sources:\n'
printf '  %s\n' "${UPDATER_FILES[@]}"

issue_matches "Client app uses GitHub Releases REST latest endpoint" 'api[.]github[.]com/repos/.*/releases/latest'
issue_matches "Unsafe quarantine stripping bypasses Gatekeeper" 'xattr[[:space:]]+-cr'
issue_matches "Fixed /Volumes mount path" '/Volumes/'
issue_matches "Swift path interpolation enters installer shell" 'TARGET=["].*\\[(]'
warning_matches "Automatic code may be using manual force/error behavior" 'checkForUpdates[(]force:[[:space:]]*true[)]'
warning_matches "Possible silent missing download URL" 'guard[[:space:]]+let.*downloadURL.*else[[:space:]]*[{][[:space:]]*return'

require_pattern "Missing HTTP response/status validation" 'HTTPURLResponse'
require_pattern "Missing release manifest validation" 'UpdateManifest|update[.]json'
require_pattern "Missing SHA-256 artifact verification" 'SHA256|sha256|shasum[[:space:]]+-a[[:space:]]+256'
require_pattern "Missing bundle identifier validation" 'CFBundleIdentifier'
require_pattern "Missing release version validation" 'CFBundleShortVersionString'
require_pattern "Missing strict code-signature verification" 'codesign[[:space:]]+--verify'
require_pattern "Missing exact Developer ID Team verification" 'TeamIdentifier|TEAM_IDENTIFIER|EXPECTED_TEAM_ID|certificate[[:space:]]+leaf\[subject[.]OU\]'
require_pattern "Missing designated-requirement verification" 'codesign.*(-R|--test-requirement)|certificate[[:space:]]+leaf\[subject[.]OU\]'
require_pattern "Missing Gatekeeper assessment" 'spctl[[:space:]]+--assess'
require_pattern "DMG is not mounted read-only" 'hdiutil[[:space:]]+attach[^\n]*-readonly'
require_pattern "Missing staged replacement" 'STAGED_APP|stagedApp'
require_pattern "Missing pre-replacement backup" 'BACKUP_APP|backupApp'
require_pattern "Missing rollback path" 'rollback|restore_backup|restoreBackup'
require_pattern "Missing post-launch process confirmation" 'pgrep|runningApplication|launchConfirmation'

printf '\nSummary: %d issue(s), %d warning(s)\n' "$issues" "$warnings"

if (( issues > 0 )); then
  exit 1
fi
