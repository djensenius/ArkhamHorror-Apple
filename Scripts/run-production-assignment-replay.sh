#!/bin/bash -p
set -euo pipefail
set +x

readonly xcode_developer_dir="/Applications/Xcode.app/Contents/Developer"
readonly xcode_application="/Applications/Xcode.app"
readonly toolchain_bin="$xcode_developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin"
readonly swift_bin="$toolchain_bin/swift"
readonly swift_target="$toolchain_bin/swift-frontend"
readonly driver_filter='ArkhamHorrorSharedTests.AssignmentReplayCoordinatorDriverSuite/runConfiguredProductionAssignmentReplayCoordinator'
readonly expected_driver_identifier='ArkhamHorrorSharedTests.AssignmentReplayCoordinatorDriverSuite/runConfiguredProductionAssignmentReplayCoordinator()'
readonly launcher_relative_path="Scripts/run-production-assignment-replay.sh"
readonly trusted_base_revision="1ae3fcc45d1dfd6e2f2bca37feec6bb1caa744fc"
readonly expected_package_tree="95d60f80e3e529e45c9611cf888f9f5faaa171f7"
readonly git_bin="/usr/bin/git"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

canonicalize_existing_path() {
  local candidate="$1"
  local current_directory directory target
  local hops=0
  case "$candidate" in
    /*) ;;
    *)
      current_directory="$(/bin/pwd -P)" || return 1
      candidate="$current_directory/$candidate"
      ;;
  esac
  while [[ -L "$candidate" ]]; do
    hops=$((hops + 1))
    (( hops <= 40 )) || return 1
    directory="$(
      cd -P -- "$(/usr/bin/dirname -- "$candidate")"
      /bin/pwd -P
    )" || return 1
    target="$(/usr/bin/readlink "$candidate")" || return 1
    case "$target" in
      /*) candidate="$target" ;;
      *) candidate="$directory/$target" ;;
    esac
  done
  directory="$(
    cd -P -- "$(/usr/bin/dirname -- "$candidate")"
    /bin/pwd -P
  )" || return 1
  printf '%s/%s\n' "$directory" "$(/usr/bin/basename -- "$candidate")"
}

usage() {
  /bin/cat >&2 <<'EOF'
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

require_trusted_repository_path() {
  local path="$1"
  local current_owner owner mode
  [[ -e "$path" && ! -L "$path" ]] ||
    fail "trusted repository path is missing or symbolic"
  current_owner="$(/usr/bin/id -u)"
  owner="$(/usr/bin/stat -f '%u' "$path")"
  mode="$(/usr/bin/stat -f '%Lp' "$path")"
  [[ "$owner" == 0 || "$owner" == "$current_owner" ]] ||
    fail "trusted repository path has an unexpected owner"
  (( (8#$mode & 0022) == 0 )) ||
    fail "trusted repository path is group- or world-writable"
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

trusted_git() {
  /usr/bin/env -i \
    GIT_ATTR_NOSYSTEM=1 \
    GIT_CONFIG_COUNT=0 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_LITERAL_PATHSPECS=1 \
    GIT_NO_REPLACE_OBJECTS=1 \
    GIT_OPTIONAL_LOCKS=0 \
    GIT_TERMINAL_PROMPT=0 \
    HOME=/nonexistent \
    LANG=C \
    LC_ALL=C \
    PATH=/usr/bin:/bin \
    TMPDIR=/tmp \
    XDG_CONFIG_HOME=/nonexistent \
    "$git_bin" \
    --no-pager \
    --git-dir="$repository_root/.git" \
    --work-tree="$repository_root" \
    -c core.attributesFile=/dev/null \
    -c core.fsmonitor=false \
    -c core.hooksPath=/dev/null \
    -c core.untrackedCache=false \
    -c diff.external= \
    -c status.showUntrackedFiles=all \
    -c status.submoduleSummary=false \
    -c submodule.recurse=false \
    "$@"
}

validate_repository_identity() {
  local top_level actual_head parent_head launcher_head package_tree
  local committed_launcher_blob working_launcher_blob
  local committed_package_blob working_package_blob origin status
  top_level="$(trusted_git rev-parse --show-toplevel)" ||
    fail "trusted repository top-level is unavailable"
  [[ "$top_level" == "$repository_root" ]] ||
    fail "trusted repository top-level does not match the launcher"

  actual_head="$(trusted_git rev-parse HEAD)" ||
    fail "trusted repository HEAD is unavailable"
  [[ "$actual_head" =~ ^[0-9a-f]{40}$ ]] ||
    fail "trusted repository HEAD is malformed"
  parent_head="$(trusted_git rev-parse HEAD^)" ||
    fail "trusted repository parent is unavailable"
  [[ "$parent_head" == "$trusted_base_revision" ]] ||
    fail "trusted repository HEAD is not the audited replay follow-up"
  launcher_head="$(
    trusted_git log -1 --format=%H -- "$launcher_relative_path"
  )" || fail "committed launcher revision is unavailable"
  [[ "$launcher_head" == "$actual_head" ]] ||
    fail "trusted repository HEAD does not own the production launcher"

  package_tree="$(
    trusted_git rev-parse "HEAD:Packages/ArkhamHorrorShared"
  )" || fail "committed replay package tree is unavailable"
  [[ "$expected_package_tree" =~ ^[0-9a-f]{40}$ &&
    "$package_tree" == "$expected_package_tree" ]] ||
    fail "committed replay package tree is not the audited tree"

  committed_launcher_blob="$(
    trusted_git rev-parse "HEAD:$launcher_relative_path"
  )" || fail "committed production launcher is unavailable"
  working_launcher_blob="$(
    trusted_git hash-object --no-filters "$canonical_launcher"
  )" || fail "production launcher identity is unavailable"
  [[ "$working_launcher_blob" == "$committed_launcher_blob" ]] ||
    fail "production launcher differs from its committed bytes"

  committed_package_blob="$(
    trusted_git rev-parse "HEAD:Packages/ArkhamHorrorShared/Package.swift"
  )" || fail "committed replay package manifest is unavailable"
  working_package_blob="$(
    trusted_git hash-object --no-filters "$package_path/Package.swift"
  )" || fail "replay package manifest identity is unavailable"
  [[ "$working_package_blob" == "$committed_package_blob" ]] ||
    fail "replay package manifest differs from its committed bytes"

  origin="$(trusted_git remote get-url origin)" ||
    fail "trusted repository origin is unavailable"
  case "$origin" in
    "https://github.com/djensenius/ArkhamHorror-Apple.git" | \
      "git@github.com:djensenius/ArkhamHorror-Apple.git" | \
      "ssh://git@github.com/djensenius/ArkhamHorror-Apple.git") ;;
    *) fail "trusted repository origin is not ArkhamHorror-Apple" ;;
  esac

  status="$(
    trusted_git status \
      --porcelain=v1 \
      --untracked-files=all \
      --ignore-submodules=none
  )" || fail "trusted repository cleanliness is unavailable"
  [[ -z "$status" ]] || fail "trusted repository worktree is not clean"
}

build_fixed_driver_without_credentials() {
  local discovered_count=0 identifier test_list
  test_list="$(
    /usr/bin/env -i \
      DEVELOPER_DIR="$xcode_developer_dir" \
      GIT_CONFIG_GLOBAL=/dev/null \
      GIT_CONFIG_NOSYSTEM=1 \
      GIT_TERMINAL_PROMPT=0 \
      HOME=/var/empty \
      LANG=C \
      LC_ALL=C \
      PATH="$toolchain_bin:/usr/bin:/bin" \
      TMPDIR=/tmp \
      "$swift_bin" test list \
      --package-path "$package_path" \
      --disable-sandbox
  )" || fail "fixed replay driver build failed"
  while IFS= read -r identifier; do
    if [[ "$identifier" == "$expected_driver_identifier" ]]; then
      discovered_count=$((discovered_count + 1))
    fi
  done <<< "$test_list"
  [[ "$discovered_count" == 1 ]] ||
    fail "fixed replay driver was not discovered exactly once"
}

reject_executable_overrides
invoked_directory="$(
  cd -P -- "$(/usr/bin/dirname -- "$0")"
  /bin/pwd -P
)" || fail "launcher invocation directory is unavailable"
invoked_launcher="$invoked_directory/$(/usr/bin/basename -- "$0")"
canonical_launcher="$(canonicalize_existing_path "$invoked_launcher")" ||
  fail "launcher canonicalization failed"
readonly invoked_launcher canonical_launcher
[[ "$invoked_launcher" == "$canonical_launcher" ]] ||
  fail "production launcher must be invoked by its canonical committed path"

script_directory="$(/usr/bin/dirname -- "$canonical_launcher")"
repository_root="$(
  cd -P -- "$script_directory/.."
  /bin/pwd -P
)" || fail "trusted repository root is unavailable"
package_path="$repository_root/Packages/ArkhamHorrorShared"
readonly script_directory repository_root package_path
[[ "$canonical_launcher" == "$repository_root/$launcher_relative_path" ]] ||
  fail "production launcher is outside the intended repository"

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
require_trusted_repository_path "$repository_root"
require_trusted_repository_path "$script_directory"
require_trusted_repository_path "$canonical_launcher"
require_trusted_repository_path "$repository_root/.git"
require_trusted_repository_path "$repository_root/Packages"
require_trusted_repository_path "$package_path"
require_trusted_repository_path "$package_path/Package.swift"
[[ -d "$repository_root" && -d "$script_directory" &&
  -f "$canonical_launcher" && -d "$package_path" &&
  -f "$package_path/Package.swift" ]] ||
  fail "trusted replay package shape is invalid"
[[ "$(cd -P -- "$package_path"; /bin/pwd -P)" == "$package_path" ]] ||
  fail "trusted replay package path is substituted"

validate_repository_identity
build_fixed_driver_without_credentials
validate_repository_identity

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
  --skip-build \
  --filter "$driver_filter"
