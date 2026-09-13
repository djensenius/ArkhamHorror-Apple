#!/bin/bash -p
set -euo pipefail

readonly xcode_developer_dir="/Applications/Xcode.app/Contents/Developer"
readonly toolchain_bin="$xcode_developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin"
readonly swift_bin="$toolchain_bin/swift"
readonly selftest_filter='^ArkhamHorrorSharedTests\.AssignmentReplayCoordinatorSelfTestSuite/'
readonly expected_driver_identifier='ArkhamHorrorSharedTests.AssignmentReplayCoordinatorDriverSuite/runConfiguredProductionAssignmentReplayCoordinator()'
readonly injected_driver_identifier='ArkhamHorrorSharedTests.AssignmentReplayCoordinatorDriverSuite/runConfiguredProductionAssignmentReplayCoordinatorInjected()'

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

readonly script_directory="$(
  cd -P -- "$(/usr/bin/dirname -- "$0")"
  /bin/pwd -P
)"
readonly repository_root="$(
  cd -P -- "$script_directory/.."
  /bin/pwd -P
)"
readonly audited_revision="$(
  /usr/bin/git -C "$repository_root" rev-parse HEAD
)"
[[ "$audited_revision" =~ ^[0-9a-f]{40}$ ]] ||
  fail "self-test repository revision is malformed"
readonly production_launcher="$script_directory/run-production-assignment-replay.sh"
readonly package_path="$repository_root/Packages/ArkhamHorrorShared"
readonly build_root="$repository_root/.build"
readonly harness_root="$build_root/production-assignment-replay-selftest.$$"
readonly fake_swift="$harness_root/fake-swift"
readonly marker="$harness_root/fake-swift-ran"
readonly override_log="$harness_root/override.log"
readonly revision_log="$harness_root/revision.log"
readonly production_log="$harness_root/production-launch.log"
readonly fake_package_root="$harness_root/fake-package"
readonly fake_package_launcher="$fake_package_root/Scripts/run-production-assignment-replay.sh"
readonly fake_package_launcher_hop="$fake_package_root/launcher-hop"
readonly fake_package_leak="$harness_root/fake-package-leak"
readonly symlink_attack_log="$harness_root/symlink-attack.log"
readonly copied_attack_log="$harness_root/copied-attack.log"
readonly sensitive_checkpoint="$harness_root/private-checkpoint-path"
readonly sensitive_output="$harness_root/private-output-path"
readonly sensitive_token="$harness_root/private-token-path"
readonly ignored_derived_data_root="$package_path/Tests/ArkhamHorrorSharedTests/DerivedData"
readonly ignored_source_root="$ignored_derived_data_root/production-assignment-replay-selftest.$$"
readonly ignored_source="$ignored_source_root/InjectedReplayDriver.swift"
readonly ignored_source_leak="$harness_root/ignored-source-leak"
created_build_root=0
created_ignored_derived_data_root=0

report_production_log() {
  /usr/bin/sed \
    -e "s#$sensitive_checkpoint#<checkpoint>#g" \
    -e "s#$sensitive_output#<output>#g" \
    -e "s#$sensitive_token#<token>#g" \
    "$production_log" >&2
}

cleanup() {
  /bin/rm -f -- "$ignored_source"
  /bin/rmdir -- "$ignored_source_root" 2>/dev/null || true
  if [[ "$created_ignored_derived_data_root" == 1 ]]; then
    /bin/rmdir -- "$ignored_derived_data_root" 2>/dev/null || true
  fi
  /bin/rm -rf -- "$harness_root"
  if [[ "$created_build_root" == 1 ]]; then
    /bin/rmdir -- "$build_root" 2>/dev/null || true
  fi
}
trap cleanup EXIT HUP INT TERM

if [[ ! -e "$build_root" ]]; then
  /bin/mkdir -m 700 "$build_root"
  created_build_root=1
fi
[[ -d "$build_root" && ! -L "$build_root" ]] ||
  fail "self-test build root is not a regular directory"
/bin/mkdir -m 700 "$harness_root"
cat >"$fake_swift" <<EOF
#!/bin/bash
/usr/bin/touch "$marker"
exit 0
EOF
/bin/chmod 700 "$fake_swift"

if ARKHAM_REPLAY_SWIFT_BIN="$fake_swift" \
  ARKHAM_REPLAY_BASE_URL="https://example.com" \
  ARKHAM_REPLAY_INVESTIGATOR_ID="c01234" \
  ARKHAM_REPLAY_ENEMY_ID="00000000-0000-0000-0000-000000000301" \
  ARKHAM_REPLAY_EXPECTED_APPLE_REVISION="$audited_revision" \
  ARKHAM_REPLAY_EXPECTED_CONTRACT_REVISION="0.1.34" \
  ARKHAM_REPLAY_EXPECTED_CATALOG_REVISION="1.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
  "$production_launcher" \
  "$harness_root/checkpoint" \
  "$harness_root/output" \
  "$harness_root/token" \
  >"$override_log" 2>&1
then
  fail "production launcher accepted an executable override"
fi
/usr/bin/grep -F \
  "ARKHAM_REPLAY_SWIFT_BIN is forbidden for production replay" \
  "$override_log" >/dev/null ||
  fail "production launcher did not reject the executable override explicitly"
[[ ! -e "$marker" ]] ||
  fail "production launcher executed a caller-selected Swift binary"
printf 'PASS: production rejects caller-selected executables\n'

if ARKHAM_REPLAY_BASE_URL="https://example.com" \
  ARKHAM_REPLAY_INVESTIGATOR_ID="c01234" \
  ARKHAM_REPLAY_ENEMY_ID="00000000-0000-0000-0000-000000000301" \
  ARKHAM_REPLAY_EXPECTED_APPLE_REVISION="0000000000000000000000000000000000000000" \
  ARKHAM_REPLAY_EXPECTED_CONTRACT_REVISION="0.1.34" \
  ARKHAM_REPLAY_EXPECTED_CATALOG_REVISION="1.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
  "$production_launcher" \
  "$harness_root/checkpoint" \
  "$harness_root/output" \
  "$harness_root/token" \
  >"$revision_log" 2>&1
then
  fail "production launcher accepted the wrong audited Apple revision"
fi
/usr/bin/grep -F \
  "trusted repository HEAD does not match the audited Apple revision" \
  "$revision_log" >/dev/null ||
  fail "production launcher did not reject the wrong Apple revision explicitly"
printf 'PASS: production requires the operator-specified Apple revision\n'

/bin/mkdir -p \
  "$fake_package_root/Scripts" \
  "$fake_package_root/Sources/ArkhamHorrorShared" \
  "$fake_package_root/Tests/ArkhamHorrorSharedTests"
cat >"$fake_package_root/Package.swift" <<'EOF'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "FakeArkhamHorrorShared",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "ArkhamHorrorShared", targets: ["ArkhamHorrorShared"]),
  ],
  targets: [
    .target(name: "ArkhamHorrorShared"),
    .testTarget(
      name: "ArkhamHorrorSharedTests",
      dependencies: ["ArkhamHorrorShared"]
    ),
  ]
)
EOF
cat >"$fake_package_root/Sources/ArkhamHorrorShared/Placeholder.swift" <<'EOF'
public enum Placeholder {}
EOF
cat >"$fake_package_root/Tests/ArkhamHorrorSharedTests/FakeReplayDriver.swift" <<EOF
import Foundation
import Testing

@Suite("Production assignment replay coordinator driver")
struct AssignmentReplayCoordinatorDriverSuite {
    @Test("Run configured production assignment replay coordinator")
    func runConfiguredProductionAssignmentReplayCoordinator() throws {
        let environment = ProcessInfo.processInfo.environment
        let leaked = [
            environment[
                "ARKHAM_PRODUCTION_ASSIGNMENT_COORDINATOR_CHECKPOINT_PATH"
            ] ?? "",
            environment[
                "ARKHAM_PRODUCTION_ASSIGNMENT_COORDINATOR_OUTPUT_DIRECTORY"
            ] ?? "",
            environment[
                "ARKHAM_PRODUCTION_ASSIGNMENT_COORDINATOR_TOKEN_PATH"
            ] ?? "",
        ].joined(separator: "\\n")
        try Data(leaked.utf8).write(
            to: URL(fileURLWithPath: "$fake_package_leak")
        )
    }
}
EOF

readonly fake_test_list="$(
  /usr/bin/env -i \
    DEVELOPER_DIR="$xcode_developer_dir" \
    HOME=/var/empty \
    LANG=C \
    LC_ALL=C \
    PATH="$toolchain_bin:/usr/bin:/bin" \
    TMPDIR=/tmp \
    "$swift_bin" test list \
    --package-path "$fake_package_root" \
    --disable-sandbox
)"
[[ "$fake_test_list" == *"$expected_driver_identifier"* ]] ||
  fail "adversarial fake package did not contain the matching driver"

/bin/ln -s "$production_launcher" "$fake_package_launcher_hop"
/bin/ln -s "../launcher-hop" "$fake_package_launcher"
if ARKHAM_REPLAY_BASE_URL="https://example.com" \
  ARKHAM_REPLAY_INVESTIGATOR_ID="c01234" \
  ARKHAM_REPLAY_ENEMY_ID="00000000-0000-0000-0000-000000000301" \
  ARKHAM_REPLAY_EXPECTED_APPLE_REVISION="$audited_revision" \
  ARKHAM_REPLAY_EXPECTED_CONTRACT_REVISION="0.1.34" \
  ARKHAM_REPLAY_EXPECTED_CATALOG_REVISION="1.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
  "$fake_package_launcher" \
  "$sensitive_checkpoint" \
  "$sensitive_output" \
  "$sensitive_token" \
  >"$symlink_attack_log" 2>&1
then
  fail "symlinked production launcher returned success"
fi
if ! /usr/bin/grep -F \
  "production launcher must be invoked by its canonical committed path" \
  "$symlink_attack_log" >/dev/null
then
  /bin/cat "$symlink_attack_log" >&2
  fail "symlinked production launcher was not rejected explicitly"
fi
[[ ! -e "$fake_package_leak" ]] ||
  fail "symlinked production launcher executed the fake package driver"
for sensitive_path in \
  "$sensitive_checkpoint" \
  "$sensitive_output" \
  "$sensitive_token"
do
  if /usr/bin/grep -F "$sensitive_path" "$symlink_attack_log" >/dev/null; then
    fail "symlinked production launcher exposed a credential path"
  fi
done

/bin/rm -f -- "$fake_package_launcher" "$fake_package_launcher_hop"
/bin/cp "$production_launcher" "$fake_package_launcher"
/bin/chmod 700 "$fake_package_launcher"
if ARKHAM_REPLAY_BASE_URL="https://example.com" \
  ARKHAM_REPLAY_INVESTIGATOR_ID="c01234" \
  ARKHAM_REPLAY_ENEMY_ID="00000000-0000-0000-0000-000000000301" \
  ARKHAM_REPLAY_EXPECTED_APPLE_REVISION="$audited_revision" \
  ARKHAM_REPLAY_EXPECTED_CONTRACT_REVISION="0.1.34" \
  ARKHAM_REPLAY_EXPECTED_CATALOG_REVISION="1.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
  "$fake_package_launcher" \
  "$sensitive_checkpoint" \
  "$sensitive_output" \
  "$sensitive_token" \
  >"$copied_attack_log" 2>&1
then
  fail "substituted production launcher returned success"
fi
[[ ! -e "$fake_package_leak" ]] ||
  fail "substituted production launcher executed the fake package driver"
for sensitive_path in \
  "$sensitive_checkpoint" \
  "$sensitive_output" \
  "$sensitive_token"
do
  if /usr/bin/grep -F "$sensitive_path" "$copied_attack_log" >/dev/null; then
    fail "substituted production launcher exposed a credential path"
  fi
done
printf 'PASS: launcher aliases cannot select a fake Swift package\n'

if [[ ! -e "$ignored_derived_data_root" ]]; then
  /bin/mkdir -m 700 "$ignored_derived_data_root"
  created_ignored_derived_data_root=1
fi
[[ -d "$ignored_derived_data_root" && ! -L "$ignored_derived_data_root" ]] ||
  fail "ignored source fixture parent is not a regular directory"
[[ ! -e "$ignored_source_root" && ! -L "$ignored_source_root" ]] ||
  fail "ignored source fixture path already exists"
/bin/mkdir -m 700 "$ignored_source_root"
/bin/cat >"$ignored_source" <<EOF
import Darwin
import Foundation
import Testing

extension AssignmentReplayCoordinatorDriverSuite {
    @Test("Ignored source injection must never execute")
    func runConfiguredProductionAssignmentReplayCoordinatorInjected() {
        let environment = ProcessInfo.processInfo.environment
        let leaked = [
            environment[
                "ARKHAM_PRODUCTION_ASSIGNMENT_COORDINATOR_CHECKPOINT_PATH"
            ] ?? "",
            environment[
                "ARKHAM_PRODUCTION_ASSIGNMENT_COORDINATOR_OUTPUT_DIRECTORY"
            ] ?? "",
            environment[
                "ARKHAM_PRODUCTION_ASSIGNMENT_COORDINATOR_TOKEN_PATH"
            ] ?? "",
        ].joined(separator: "\\n")
        try? Data(leaked.utf8).write(
            to: URL(fileURLWithPath: "$ignored_source_leak")
        )
        _exit(0)
    }
}
EOF
/usr/bin/git -C "$repository_root" check-ignore -q -- "$ignored_source" ||
  fail "adversarial Swift source is not ignored"
[[ -z "$(/usr/bin/git -C "$repository_root" status --porcelain=v1)" ]] ||
  fail "adversarial Swift source unexpectedly dirtied Git status"

readonly mutable_test_list="$(
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
)"
[[ "$mutable_test_list" == *"$injected_driver_identifier"* ]] ||
  fail "adversarial ignored Swift source was not discovered by SwiftPM"
readonly worktree_list_before="$(
  /usr/bin/git -C "$repository_root" worktree list --porcelain
)"

if PATH="$harness_root" \
  ARKHAM_REPLAY_BASE_URL="http://example.com" \
  ARKHAM_REPLAY_INVESTIGATOR_ID="c01234" \
  ARKHAM_REPLAY_ENEMY_ID="00000000-0000-0000-0000-000000000301" \
  ARKHAM_REPLAY_EXPECTED_APPLE_REVISION="$audited_revision" \
  ARKHAM_REPLAY_EXPECTED_CONTRACT_REVISION="0.1.34" \
  ARKHAM_REPLAY_EXPECTED_CATALOG_REVISION="1.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
  "$production_launcher" \
  "$harness_root/missing-checkpoint" \
  "$harness_root/output" \
  "$harness_root/missing-token" \
  >"$production_log" 2>&1
then
  fail "invalid production configuration returned success"
fi
[[ ! -e "$marker" ]] ||
  fail "poisoned PATH selected a fake Swift executable"
[[ ! -e "$ignored_source_leak" ]] ||
  fail "production compiled or executed an ignored Swift source"
[[ ! -e "$harness_root/output" ]] ||
  fail "invalid server URL reached credential or output handling"
if /usr/bin/grep -F "No matching test cases" "$production_log" >/dev/null; then
  fail "production launcher selected no replay driver test"
fi
if ! /usr/bin/grep -F \
  'Suite "Production assignment replay coordinator driver" started.' \
  "$production_log" >/dev/null
then
  report_production_log
  fail "production launcher did not execute the fixed coordinator driver"
fi
for sensitive_path in \
  "$sensitive_checkpoint" \
  "$sensitive_output" \
  "$sensitive_token"
do
  if /usr/bin/grep -F "$sensitive_path" "$production_log" >/dev/null; then
    fail "production launcher exposed a credential path in output"
  fi
done
readonly worktree_list_after="$(
  /usr/bin/git -C "$repository_root" worktree list --porcelain
)"
[[ "$worktree_list_after" == "$worktree_list_before" ]] ||
  fail "production launcher left a private worktree registered"
printf 'PASS: production isolates ignored Swift sources in a committed checkout\n'

readonly test_list="$(
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
)"
[[ "$test_list" == *"$expected_driver_identifier"* ]] ||
  fail "production driver filter no longer names a discovered test"

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
  "$swift_bin" test \
  --package-path "$package_path" \
  --disable-sandbox \
  --no-parallel \
  --filter "$selftest_filter"

printf 'PASS: Swift-only coordinator self-test harness\n'
