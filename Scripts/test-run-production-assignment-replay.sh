#!/bin/bash -p
set -euo pipefail

readonly xcode_developer_dir="/Applications/Xcode.app/Contents/Developer"
readonly toolchain_bin="$xcode_developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin"
readonly swift_bin="$toolchain_bin/swift"
readonly selftest_filter='^ArkhamHorrorSharedTests\.AssignmentReplayCoordinatorSelfTestSuite/'
readonly expected_driver_identifier='ArkhamHorrorSharedTests.AssignmentReplayCoordinatorDriverSuite/runConfiguredProductionAssignmentReplayCoordinator()'

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
readonly production_launcher="$script_directory/run-production-assignment-replay.sh"
readonly package_path="$repository_root/Packages/ArkhamHorrorShared"
readonly build_root="$repository_root/.build"
readonly harness_root="$build_root/production-assignment-replay-selftest.$$"
readonly fake_swift="$harness_root/fake-swift"
readonly marker="$harness_root/fake-swift-ran"
readonly override_log="$harness_root/override.log"
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
created_build_root=0

cleanup() {
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
  ARKHAM_REPLAY_EXPECTED_CONTRACT_REVISION="0.1.33" \
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
  ARKHAM_REPLAY_EXPECTED_CONTRACT_REVISION="0.1.33" \
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
  ARKHAM_REPLAY_EXPECTED_CONTRACT_REVISION="0.1.33" \
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

if PATH="$harness_root" \
  ARKHAM_REPLAY_BASE_URL="http://example.com" \
  ARKHAM_REPLAY_INVESTIGATOR_ID="c01234" \
  ARKHAM_REPLAY_ENEMY_ID="00000000-0000-0000-0000-000000000301" \
  ARKHAM_REPLAY_EXPECTED_CONTRACT_REVISION="0.1.33" \
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
[[ ! -e "$harness_root/output" ]] ||
  fail "invalid server URL reached credential or output handling"
if /usr/bin/grep -F "No matching test cases" "$production_log" >/dev/null; then
  fail "production launcher selected no replay driver test"
fi
/usr/bin/grep -F \
  'Suite "Production assignment replay coordinator driver" started.' \
  "$production_log" >/dev/null ||
  fail "production launcher did not execute the fixed coordinator driver"
printf 'PASS: production uses the fixed sanitized Swift coordinator path\n'

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
