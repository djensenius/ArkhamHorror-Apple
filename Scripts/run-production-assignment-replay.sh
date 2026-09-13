#!/bin/bash -p
set -euo pipefail
set +x

readonly xcode_developer_dir="/Applications/Xcode.app/Contents/Developer"
readonly xcode_application="/Applications/Xcode.app"
readonly toolchain_bin="$xcode_developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin"
readonly swift_bin="$toolchain_bin/swift"
readonly swift_target="$toolchain_bin/swift-frontend"
readonly driver_identifier_prefix='ArkhamHorrorSharedTests.AssignmentReplayCoordinatorDriverSuite/runConfiguredProductionAssignmentReplayCoordinator'
readonly expected_driver_identifier="${driver_identifier_prefix}()"
readonly driver_filter='^ArkhamHorrorSharedTests\.AssignmentReplayCoordinatorDriverSuite/runConfiguredProductionAssignmentReplayCoordinator\(\)(/[^/]+)?$'
readonly launcher_relative_path="Scripts/run-production-assignment-replay.sh"
readonly trusted_base_revision="5a00e3bff0786864ffc909fa5e054600d68d4079"
readonly expected_package_tree="a566501a3c4135364cf11f5f4806fa56ee9598b2"
readonly trusted_scratch_parent="/private/tmp"
readonly git_bin="/usr/bin/git"

verified_head=""
verified_repository_tree=""
repository_git_directory=""
scratch_root=""
scratch_root_identity=""
materialized_repository=""
materialized_repository_identity=""
materialized_git_directory=""
materialized_package_path=""

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
  ARKHAM_REPLAY_EXPECTED_APPLE_REVISION
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

resolve_repository_git_directory() {
  local actual_git_directory canonical_git_directory
  actual_git_directory="$(
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
      -C "$repository_root" \
      rev-parse --absolute-git-dir
  )" || fail "source checkout Git directory is unavailable"
  case "$actual_git_directory" in
    /*) ;;
    *) fail "source checkout Git directory is not absolute" ;;
  esac
  canonical_git_directory="$(
    canonicalize_existing_path "$actual_git_directory"
  )" || fail "source checkout Git directory canonicalization failed"
  [[ "$canonical_git_directory" == "$actual_git_directory" ]] ||
    fail "source checkout Git directory is not canonical"
  require_trusted_repository_path "$canonical_git_directory"
  [[ -d "$canonical_git_directory" ]] ||
    fail "source checkout Git directory is not a directory"
  repository_git_directory="$canonical_git_directory"
}

trusted_git() {
  [[ -n "$repository_git_directory" ]] ||
    fail "source checkout Git directory was not resolved"
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
    --git-dir="$repository_git_directory" \
    --work-tree="$repository_root" \
    -c core.attributesFile=/dev/null \
    -c core.autocrlf=false \
    -c core.eol=lf \
    -c core.excludesFile=/dev/null \
    -c core.fsmonitor=false \
    -c core.hooksPath=/dev/null \
    -c core.ignoreStat=false \
    -c core.sparseCheckout=false \
    -c core.sparseCheckoutCone=false \
    -c core.untrackedCache=false \
    -c diff.external= \
    -c status.showUntrackedFiles=all \
    -c status.submoduleSummary=false \
    -c submodule.recurse=false \
    "$@"
}

validate_repository_identity() {
  local top_level actual_head actual_tree object_type
  local parent_head launcher_head package_tree
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
  [[ "$ARKHAM_REPLAY_EXPECTED_APPLE_REVISION" =~ ^[0-9a-f]{40}$ ]] ||
    fail "expected Apple revision is malformed"
  [[ "$actual_head" == "$ARKHAM_REPLAY_EXPECTED_APPLE_REVISION" ]] ||
    fail "trusted repository HEAD does not match the audited Apple revision"
  object_type="$(trusted_git cat-file -t "$actual_head")" ||
    fail "trusted repository HEAD object is unavailable"
  [[ "$object_type" == "commit" ]] ||
    fail "trusted repository HEAD is not a commit"
  actual_tree="$(trusted_git rev-parse "$actual_head^{tree}")" ||
    fail "trusted repository tree is unavailable"
  [[ "$actual_tree" =~ ^[0-9a-f]{40}$ ]] ||
    fail "trusted repository tree is malformed"
  if [[ -n "$verified_head" ]]; then
    [[ "$actual_head" == "$verified_head" &&
      "$actual_tree" == "$verified_repository_tree" ]] ||
      fail "trusted repository changed during replay preparation"
  else
    verified_head="$actual_head"
    verified_repository_tree="$actual_tree"
  fi
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
    "https://github.com/djensenius/ArkhamHorror-Apple" | \
      "https://github.com/djensenius/ArkhamHorror-Apple.git" | \
      "git@github.com:djensenius/ArkhamHorror-Apple" | \
      "git@github.com:djensenius/ArkhamHorror-Apple.git" | \
      "ssh://git@github.com/djensenius/ArkhamHorror-Apple" | \
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

path_identity() {
  /usr/bin/stat -f '%d:%i' "$1"
}

owned_private_directory_matches() {
  local path="$1"
  local expected_identity="${2:-}"
  local canonical identity mode owner
  [[ -d "$path" && ! -L "$path" ]] || return 1
  owner="$(/usr/bin/stat -f '%u' "$path")" || return 1
  mode="$(/usr/bin/stat -f '%Lp' "$path")" || return 1
  [[ "$owner" == "$(/usr/bin/id -u)" && "$mode" == 700 ]] || return 1
  canonical="$(
    cd -P -- "$path"
    /bin/pwd -P
  )" || return 1
  [[ "$canonical" == "$path" ]] || return 1
  if [[ -n "$expected_identity" ]]; then
    identity="$(path_identity "$path")" || return 1
    [[ "$identity" == "$expected_identity" ]] || return 1
  fi
}

require_owned_private_directory() {
  owned_private_directory_matches "$1" "${2:-}" ||
    fail "private replay directory identity is unsafe"
}

validate_trusted_scratch_parent() {
  local mode owner
  require_trusted_toolchain_path "/"
  require_trusted_toolchain_path "/private"
  [[ -d "$trusted_scratch_parent" && ! -L "$trusted_scratch_parent" ]] ||
    fail "trusted replay scratch parent is unavailable"
  owner="$(/usr/bin/stat -f '%u' "$trusted_scratch_parent")"
  mode="$(/usr/bin/stat -f '%Lp' "$trusted_scratch_parent")"
  [[ "$owner" == 0 && "$mode" == 777 &&
    -k "$trusted_scratch_parent" ]] ||
    fail "trusted replay scratch parent identity is unsafe"
}

materialized_git() {
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
    --git-dir="$materialized_git_directory" \
    --work-tree="$materialized_repository" \
    -c core.attributesFile=/dev/null \
    -c core.autocrlf=false \
    -c core.eol=lf \
    -c core.excludesFile=/dev/null \
    -c core.fsmonitor=false \
    -c core.hooksPath=/dev/null \
    -c core.ignoreStat=false \
    -c core.sparseCheckout=false \
    -c core.sparseCheckoutCone=false \
    -c core.untrackedCache=false \
    -c diff.external= \
    -c status.showUntrackedFiles=all \
    -c status.submoduleSummary=false \
    -c submodule.recurse=false \
    "$@"
}

worktree_is_registered() {
  local line listing
  listing="$(trusted_git worktree list --porcelain)" || return 1
  while IFS= read -r line; do
    [[ "$line" == "worktree $materialized_repository" ]] && return 0
  done <<< "$listing"
  return 1
}

cleanup_materialized_repository() {
  local exit_status=$?
  local checkout_safe=0 cleanup_failed=0 scratch_safe=0
  trap - EXIT HUP INT TERM
  set +e

  if [[ -n "$scratch_root" ]]; then
    if owned_private_directory_matches \
      "$scratch_root" \
      "$scratch_root_identity"
    then
      scratch_safe=1
    else
      printf 'error: private replay scratch identity changed; refusing cleanup\n' >&2
      cleanup_failed=1
    fi
  fi

  if [[ "$scratch_safe" == 1 && -n "$materialized_repository" ]]; then
    if [[ ! -e "$materialized_repository" &&
      ! -L "$materialized_repository" ]]
    then
      checkout_safe=1
    elif [[ -n "$materialized_repository_identity" ]] &&
      owned_private_directory_matches \
        "$materialized_repository" \
        "$materialized_repository_identity"
    then
      checkout_safe=1
    else
      printf 'error: private replay checkout identity changed; refusing cleanup\n' >&2
      cleanup_failed=1
    fi

    if [[ "$checkout_safe" == 1 ]]; then
      if worktree_is_registered; then
        trusted_git worktree remove --force "$materialized_repository" \
          >/dev/null 2>&1 ||
          cleanup_failed=1
      elif [[ -e "$materialized_repository" ||
        -L "$materialized_repository" ]]
      then
        printf 'error: private replay checkout is not registered; refusing cleanup\n' >&2
        cleanup_failed=1
      fi
    fi
  fi

  if [[ "$scratch_safe" == 1 ]]; then
    if [[ -e "$materialized_repository" ||
      -L "$materialized_repository" ]]
    then
      cleanup_failed=1
    elif ! /bin/rmdir -- "$scratch_root"; then
      cleanup_failed=1
    fi
  fi

  if [[ "$cleanup_failed" == 1 ]]; then
    printf 'error: private replay checkout cleanup failed\n' >&2
    [[ "$exit_status" == 0 ]] && exit_status=1
  fi
  exit "$exit_status"
}

create_materialized_repository() {
  local common_git_directory scratch_name
  validate_trusted_scratch_parent
  common_git_directory="$(trusted_git rev-parse --git-common-dir)" ||
    fail "repository common git directory is unavailable"
  [[ "$common_git_directory" == /* ]] ||
    fail "repository common git directory is not absolute"
  require_trusted_repository_path "$common_git_directory"
  umask 077
  scratch_root="$(
    /usr/bin/mktemp -d \
      "$trusted_scratch_parent/arkham-production-assignment-replay.XXXXXXXX"
  )" || fail "private replay scratch creation failed"
  /bin/chmod 700 "$scratch_root" ||
    fail "private replay scratch permissions could not be fixed"
  scratch_name="$(/usr/bin/basename -- "$scratch_root")"
  [[ "$(/usr/bin/dirname -- "$scratch_root")" == "$trusted_scratch_parent" &&
    "$scratch_name" == arkham-production-assignment-replay.* ]] ||
    fail "private replay scratch path is outside the trusted parent"
  require_owned_private_directory "$scratch_root"
  scratch_root_identity="$(path_identity "$scratch_root")" ||
    fail "private replay scratch identity is unavailable"

  materialized_repository="$scratch_root/checkout"
  trusted_git worktree add \
    --detach \
    "$materialized_repository" \
    "$verified_head" \
    >/dev/null ||
    fail "committed replay checkout materialization failed"
  /bin/chmod 700 "$materialized_repository" ||
    fail "committed replay checkout permissions could not be fixed"
  require_owned_private_directory "$materialized_repository"
  materialized_repository_identity="$(
    path_identity "$materialized_repository"
  )" || fail "committed replay checkout identity is unavailable"
  materialized_git_directory="$(
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
      -C "$materialized_repository" \
      rev-parse --absolute-git-dir
  )" || fail "materialized replay git directory is unavailable"
  case "$materialized_git_directory" in
    "$common_git_directory/worktrees/"*) ;;
    *) fail "materialized replay git directory is outside repository metadata" ;;
  esac
  require_trusted_repository_path "$materialized_git_directory"
  materialized_package_path="$materialized_repository/Packages/ArkhamHorrorShared"
}

validate_materialized_repository() {
  local actual_head actual_tree index_entry index_flags index_tree
  local object_type package_tree staged_entries status top_level
  require_owned_private_directory "$scratch_root" "$scratch_root_identity"
  require_owned_private_directory \
    "$materialized_repository" \
    "$materialized_repository_identity"
  require_trusted_repository_path "$materialized_repository/.git"
  require_trusted_repository_path "$materialized_repository/Packages"
  require_trusted_repository_path "$materialized_package_path"
  require_trusted_repository_path "$materialized_package_path/Package.swift"

  top_level="$(materialized_git rev-parse --show-toplevel)" ||
    fail "committed replay checkout top-level is unavailable"
  [[ "$top_level" == "$materialized_repository" ]] ||
    fail "committed replay checkout top-level is incorrect"
  actual_head="$(materialized_git rev-parse HEAD)" ||
    fail "committed replay checkout HEAD is unavailable"
  object_type="$(materialized_git cat-file -t "$actual_head")" ||
    fail "committed replay checkout HEAD object is unavailable"
  actual_tree="$(materialized_git rev-parse "$actual_head^{tree}")" ||
    fail "committed replay checkout tree is unavailable"
  index_tree="$(materialized_git write-tree)" ||
    fail "committed replay checkout index is unavailable"
  package_tree="$(
    materialized_git rev-parse "HEAD:Packages/ArkhamHorrorShared"
  )" || fail "committed replay package tree is unavailable"
  [[ "$object_type" == "commit" &&
    "$actual_head" == "$verified_head" &&
    "$actual_tree" == "$verified_repository_tree" &&
    "$index_tree" == "$verified_repository_tree" &&
    "$package_tree" == "$expected_package_tree" ]] ||
    fail "committed replay checkout identity is incorrect"
  index_flags="$(materialized_git ls-files -v)" ||
    fail "committed replay checkout index flags are unavailable"
  while IFS= read -r index_entry; do
    [[ "$index_entry" == H\ * ]] ||
      fail "committed replay checkout has hidden index entries"
  done <<< "$index_flags"
  staged_entries="$(materialized_git ls-files --stage)" ||
    fail "committed replay checkout staged entries are unavailable"
  while IFS=' ' read -r index_entry _; do
    [[ "$index_entry" != 120000 && "$index_entry" != 160000 ]] ||
      fail "committed replay checkout contains redirected tracked content"
  done <<< "$staged_entries"
  if materialized_git symbolic-ref -q HEAD >/dev/null 2>&1; then
    fail "committed replay checkout is not detached"
  fi
  status="$(
    materialized_git status \
      --porcelain=v1 \
      --untracked-files=all \
      --ignored=matching \
      --ignore-submodules=none
  )" || fail "committed replay checkout status is unavailable"
  [[ -z "$status" ]] ||
    fail "committed replay checkout contains non-committed bytes"
}

validate_materialized_repository_after_build() {
  local actual_head actual_tree index_tree status
  require_owned_private_directory "$scratch_root" "$scratch_root_identity"
  require_owned_private_directory \
    "$materialized_repository" \
    "$materialized_repository_identity"
  actual_head="$(materialized_git rev-parse HEAD)" ||
    fail "built replay checkout HEAD is unavailable"
  actual_tree="$(materialized_git rev-parse "$actual_head^{tree}")" ||
    fail "built replay checkout tree is unavailable"
  index_tree="$(materialized_git write-tree)" ||
    fail "built replay checkout index is unavailable"
  [[ "$actual_head" == "$verified_head" &&
    "$actual_tree" == "$verified_repository_tree" &&
    "$index_tree" == "$verified_repository_tree" ]] ||
    fail "built replay checkout identity changed"
  status="$(
    materialized_git status \
      --porcelain=v1 \
      --untracked-files=all \
      --ignore-submodules=none
  )" || fail "built replay checkout status is unavailable"
  [[ -z "$status" ]] ||
    fail "build modified committed replay checkout bytes"
}

build_fixed_driver_without_credentials() {
  local discovered_count=0 exact_count=0 identifier test_list
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
      --package-path "$materialized_package_path" \
      --disable-sandbox
  )" || fail "fixed replay driver build failed"
  while IFS= read -r identifier; do
    if [[ "$identifier" == "$driver_identifier_prefix"* ]]; then
      discovered_count=$((discovered_count + 1))
    fi
    if [[ "$identifier" == "$expected_driver_identifier" ]]; then
      exact_count=$((exact_count + 1))
    fi
  done <<< "$test_list"
  [[ "$discovered_count" == 1 && "$exact_count" == 1 ]] ||
    fail "fixed replay driver identifier is missing or ambiguous"
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
trap cleanup_materialized_repository EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[[ "$#" == 3 ]] || {
  usage
  exit 2
}
require_environment ARKHAM_REPLAY_BASE_URL
require_environment ARKHAM_REPLAY_INVESTIGATOR_ID
require_environment ARKHAM_REPLAY_ENEMY_ID
require_environment ARKHAM_REPLAY_EXPECTED_APPLE_REVISION
require_environment ARKHAM_REPLAY_EXPECTED_CONTRACT_REVISION
require_environment ARKHAM_REPLAY_EXPECTED_CATALOG_REVISION
validate_toolchain
require_trusted_repository_path "$repository_root"
require_trusted_repository_path "$script_directory"
require_trusted_repository_path "$canonical_launcher"
require_trusted_repository_path "$repository_root/.git"
resolve_repository_git_directory
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
create_materialized_repository
validate_materialized_repository
validate_repository_identity
build_fixed_driver_without_credentials
validate_materialized_repository_after_build
validate_repository_identity

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
  --package-path "$materialized_package_path" \
  --disable-sandbox \
  --no-parallel \
  --skip-build \
  --filter "$driver_filter"
