#!/bin/bash -p
set -euo pipefail
set +x

readonly xcode_developer_dir="/Applications/Xcode.app/Contents/Developer"
readonly xcode_application="/Applications/Xcode.app"
readonly toolchain_bin="$xcode_developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin"
readonly swift_bin="$toolchain_bin/swift"
readonly swift_target="$toolchain_bin/swift-frontend"
readonly driver_filter='ArkhamHorrorSharedTests.AssignmentReplayCoordinatorDriverSuite/runConfiguredProductionAssignmentReplayCoordinator'

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage: Scripts/run-production-assignment-replay.sh CHECKPOINT_JSON OUTPUT_DIRECTORY TOKEN_FILE

Required environment:
  ARKHAM_REPLAY_BASE_URL
  ARKHAM_REPLAY_INVESTIGATOR_ID
  ARKHAM_REPLAY_ENEMY_ID
  ARKHAM_REPLAY_EXPECTED_CONTRACT_REVISION
  ARKHAM_REPLAY_EXPECTED_CATALOG_REVISION

Optional environment:
  ARKHAM_REPLAY_SERVER_PROFILE_ID  (default: 00000000-0000-0000-0000-000000000777)
  ARKHAM_REPLAY_DEADLINE_SECONDS   (default: 60)
EOF
}

reject_executable_overrides() {
  local name
  for name in \
    ARKHAM_REPLAY_CURL_BIN \
    ARKHAM_REPLAY_PYTHON_BIN \
    ARKHAM_REPLAY_SWIFT_BIN \
    ARKHAM_REPLAY_GIT_BIN \
    SWIFT_EXEC \
    DEVELOPER_DIR \
    TOOLCHAINS \
    SDKROOT
  do
    if [[ "${!name+x}" == x ]]; then
      fail "$name is forbidden for production replay"
    fi
  done
}

require_environment() {
  local name="$1"
  [[ -n "${!name:-}" ]] || fail "$name is required"
}

require_trusted_toolchain_path() {
  local path="$1"
  local current_owner owner mode
  [[ -e "$path" ]] || fail "trusted toolchain path is missing: $path"
  current_owner="$(/usr/bin/id -u)"
  owner="$(/usr/bin/stat -f '%u' "$path")"
  mode="$(/usr/bin/stat -f '%Lp' "$path")"
  [[ "$owner" == 0 || "$owner" == "$current_owner" ]] ||
    fail "trusted toolchain path has an unexpected owner: $path"
  (( (8#$mode & 0022) == 0 )) ||
    fail "trusted toolchain path is group- or world-writable: $path"
}

validate_toolchain() {
  local path
  for path in \
    "$xcode_application" \
    "$xcode_application/Contents" \
    "$xcode_developer_dir" \
    "$xcode_developer_dir/Toolchains" \
    "$xcode_developer_dir/Toolchains/XcodeDefault.xctoolchain" \
    "$xcode_developer_dir/Toolchains/XcodeDefault.xctoolchain/usr" \
    "$toolchain_bin" \
    "$swift_target"
  do
    require_trusted_toolchain_path "$path"
  done
  /usr/bin/codesign --verify --deep --strict \
    -R='anchor apple and identifier "com.apple.dt.Xcode"' \
    "$xcode_application" ||
    fail "pinned Xcode application failed Apple code-signature validation"
  [[ -L "$swift_bin" ]] ||
    fail "trusted Swift launcher must be the Xcode toolchain symlink"
  [[ "$(/usr/bin/readlink "$swift_bin")" == "swift-frontend" ]] ||
    fail "trusted Swift launcher resolves outside the pinned toolchain"
  [[ -f "$swift_target" && -x "$swift_target" && ! -L "$swift_target" ]] ||
    fail "trusted Swift frontend is not a regular executable"
}

reject_executable_overrides
[[ "$#" == 3 ]] || {
  usage
  exit 2
}
require_environment ARKHAM_REPLAY_BASE_URL
require_environment ARKHAM_REPLAY_INVESTIGATOR_ID
require_environment ARKHAM_REPLAY_ENEMY_ID
require_environment ARKHAM_REPLAY_EXPECTED_CONTRACT_REVISION
require_environment ARKHAM_REPLAY_EXPECTED_CATALOG_REVISION
validate_toolchain

readonly script_directory="$(
  cd -P -- "$(/usr/bin/dirname -- "$0")"
  /bin/pwd -P
)"
readonly repository_root="$(
  cd -P -- "$script_directory/.."
  /bin/pwd -P
)"
readonly package_path="$repository_root/Packages/ArkhamHorrorShared"
[[ -f "$package_path/Package.swift" ]] ||
  fail "trusted ArkhamHorrorShared package path is missing"

exec /usr/bin/env -i \
  DEVELOPER_DIR="$xcode_developer_dir" \
  GIT_CONFIG_GLOBAL=/dev/null \
  GIT_CONFIG_NOSYSTEM=1 \
  GIT_TERMINAL_PROMPT=0 \
  HOME=/var/empty \
  LANG=C \
  LC_ALL=C \
  PATH="$toolchain_bin:/usr/bin:/bin" \
  TMPDIR=/tmp \
  ARKHAM_PRODUCTION_ASSIGNMENT_COORDINATOR_SERVER_BASE_URL="$ARKHAM_REPLAY_BASE_URL" \
  ARKHAM_PRODUCTION_ASSIGNMENT_COORDINATOR_SERVER_PROFILE_ID="${ARKHAM_REPLAY_SERVER_PROFILE_ID:-00000000-0000-0000-0000-000000000777}" \
  ARKHAM_PRODUCTION_ASSIGNMENT_COORDINATOR_CHECKPOINT_PATH="$1" \
  ARKHAM_PRODUCTION_ASSIGNMENT_COORDINATOR_TOKEN_PATH="$3" \
  ARKHAM_PRODUCTION_ASSIGNMENT_COORDINATOR_OUTPUT_DIRECTORY="$2" \
  ARKHAM_PRODUCTION_ASSIGNMENT_COORDINATOR_DEADLINE_SECONDS="${ARKHAM_REPLAY_DEADLINE_SECONDS:-60}" \
  ARKHAM_PRODUCTION_ASSIGNMENT_COORDINATOR_EXPECTED_CONTRACT_REVISION="$ARKHAM_REPLAY_EXPECTED_CONTRACT_REVISION" \
  ARKHAM_PRODUCTION_ASSIGNMENT_COORDINATOR_EXPECTED_CATALOG_REVISION="$ARKHAM_REPLAY_EXPECTED_CATALOG_REVISION" \
  ARKHAM_PRODUCTION_ASSIGNMENT_COORDINATOR_ENEMY_ID="$ARKHAM_REPLAY_ENEMY_ID" \
  ARKHAM_PRODUCTION_ASSIGNMENT_COORDINATOR_INVESTIGATOR_ID="$ARKHAM_REPLAY_INVESTIGATOR_ID" \
  "$swift_bin" test \
  --package-path "$package_path" \
  --disable-sandbox \
  --no-parallel \
  --filter "$driver_filter"
