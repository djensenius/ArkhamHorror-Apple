#!/bin/bash -p
set -euo pipefail

readonly xcode_developer_dir="/Applications/Xcode.app/Contents/Developer"
readonly toolchain_bin="$xcode_developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin"
readonly swift_bin="$toolchain_bin/swift"
readonly selftest_filter='^ArkhamHorrorSharedTests\.AssignmentReplayCoordinatorSelfTestSuite/'
readonly expected_driver_identifier='ArkhamHorrorSharedTests.AssignmentReplayCoordinatorDriverSuite/runConfiguredProductionAssignmentReplayCoordinator()'
readonly injected_driver_identifier='ArkhamHorrorSharedTests.AssignmentReplayCoordinatorDriverSuite/runConfiguredProductionAssignmentReplayCoordinatorInjected()'
readonly current_contract_revision="0.1.48"
readonly xcode_application="/Applications/Xcode.app"
readonly expected_xcode_signature_requirement='(anchor apple or (anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9])) and identifier "com.apple.dt.Xcode"'
readonly xcode_signature_requirement_prefix="readonly xcode_signature_requirement='"
readonly xcode_identifier_clause=' and identifier "com.apple.dt.Xcode"'
readonly apple_platform_application="/System/Applications/Calculator.app"

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
readonly scenario_log="$harness_root/scenario.log"
readonly production_log="$harness_root/production-launch.log"
readonly signature_log="$harness_root/signature.log"
readonly adhoc_xcode_fixture="$harness_root/signature-fixture/Xcode.app"
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
created_harness_root=0
created_ignored_derived_data_root=0
created_ignored_source_root=0
build_root_identity=""
harness_root_identity=""
ignored_derived_data_root_identity=""
ignored_source_root_identity=""

path_identity() {
  /usr/bin/stat -f '%d:%i' "$1"
}

owned_directory_matches() {
  local path="$1"
  local expected_identity="$2"
  [[ -n "$expected_identity" && -d "$path" && ! -L "$path" ]] ||
    return 1
  [[ "$(path_identity "$path")" == "$expected_identity" ]] ||
    return 1
  [[ "$(/usr/bin/stat -f '%u' "$path")" == "$(/usr/bin/id -u)" ]]
}

owned_private_directory_matches() {
  owned_directory_matches "$1" "$2" &&
    [[ "$(/usr/bin/stat -f '%Lp' "$1")" == 700 ]]
}

report_production_log() {
  /usr/bin/sed \
    -e "s#$sensitive_checkpoint#<checkpoint>#g" \
    -e "s#$sensitive_output#<output>#g" \
    -e "s#$sensitive_token#<token>#g" \
    "$production_log" >&2
}

# codesign exits 0 when the requirement holds, 3 when a valid signature does
# not satisfy it, and 1 when the signature itself is invalid.
expect_signature_verdict() {
  local expected_status="$1"
  local requirement="$2"
  local code_path="$3"
  local description="$4"
  local status=0
  /usr/bin/codesign --verify --deep --strict \
    -R="$requirement" \
    "$code_path" \
    >"$signature_log" 2>&1 || status=$?
  if [[ "$status" != "$expected_status" ]]; then
    /bin/cat "$signature_log" >&2
    fail "$description (codesign exit $status, expected $expected_status)"
  fi
}

leaf_signing_authority() {
  local details
  details="$(/usr/bin/codesign -d --verbose=2 "$1" 2>&1)" || return 1
  /usr/bin/sed -n '/^Authority=/{s/^Authority=//p;q;}' <<<"$details"
}

# Sets selected_application to the first candidate of the given kind
# (app-store or developer-id) that is not signed as Xcode and whose signature
# verifies on its own, or to "" when none qualifies. Cheap signature metadata
# is checked first; only remaining candidates are verified.
selected_application=""
select_signed_application() {
  local kind="$1"
  shift
  local candidate details identifier leaf status
  selected_application=""
  for candidate in "$@"; do
    [[ -d "$candidate" ]] || continue
    if [[ "$kind" == app-store && ! -e "$candidate/Contents/_MASReceipt" ]]; then
      continue
    fi
    details="$(/usr/bin/codesign -d --verbose=2 "$candidate" 2>&1)" || continue
    leaf="$(/usr/bin/sed -n '/^Authority=/{s/^Authority=//p;q;}' <<<"$details")"
    case "$kind:$leaf" in
      "app-store:Apple Mac OS Application Signing") ;;
      "developer-id:Developer ID Application: "*) ;;
      *) continue ;;
    esac
    identifier="$(/usr/bin/sed -n 's/^Identifier=//p' <<<"$details")"
    if [[ "$identifier" == com.apple.dt.Xcode ]]; then
      printf 'note: skipping %s: signed as com.apple.dt.Xcode\n' "$candidate"
      continue
    fi
    status=0
    /usr/bin/codesign --verify --deep --strict "$candidate" \
      >"$signature_log" 2>&1 || status=$?
    if [[ "$status" != 0 ]]; then
      printf 'note: skipping %s: its signature does not verify (codesign exit %s)\n' \
        "$candidate" \
        "$status"
      continue
    fi
    selected_application="$candidate"
    return 0
  done
}

cleanup() {
  local exit_status=$?
  local cleanup_failed=0
  trap - EXIT HUP INT TERM
  set +e

  if [[ "$created_ignored_source_root" == 1 ]]; then
    if owned_directory_matches \
      "$ignored_derived_data_root" \
      "$ignored_derived_data_root_identity" &&
      owned_private_directory_matches \
        "$ignored_source_root" \
        "$ignored_source_root_identity"
    then
      /bin/rm -f -- "$ignored_source" || cleanup_failed=1
      /bin/rmdir -- "$ignored_source_root" 2>/dev/null ||
        cleanup_failed=1
    else
      printf 'FAIL: refusing cleanup of unowned ignored-source path\n' >&2
      cleanup_failed=1
    fi
  fi

  if [[ "$created_ignored_derived_data_root" == 1 ]]; then
    if owned_directory_matches \
      "$ignored_derived_data_root" \
      "$ignored_derived_data_root_identity"
    then
      /bin/rmdir -- "$ignored_derived_data_root" 2>/dev/null ||
        cleanup_failed=1
    else
      printf 'FAIL: refusing cleanup of unowned ignored-source parent\n' >&2
      cleanup_failed=1
    fi
  fi

  if [[ "$created_harness_root" == 1 ]]; then
    if owned_directory_matches "$build_root" "$build_root_identity" &&
      owned_private_directory_matches \
        "$harness_root" \
        "$harness_root_identity"
    then
      /bin/rm -rf -- "$harness_root" || cleanup_failed=1
    else
      printf 'FAIL: refusing cleanup of unowned harness path\n' >&2
      cleanup_failed=1
    fi
  fi

  if [[ "$created_build_root" == 1 ]]; then
    if owned_directory_matches "$build_root" "$build_root_identity"; then
      /bin/rmdir -- "$build_root" 2>/dev/null || cleanup_failed=1
    else
      printf 'FAIL: refusing cleanup of unowned build root\n' >&2
      cleanup_failed=1
    fi
  fi

  if [[ "$cleanup_failed" == 1 && "$exit_status" == 0 ]]; then
    exit_status=1
  fi
  exit "$exit_status"
}
trap cleanup EXIT HUP INT TERM

if [[ ! -e "$build_root" ]]; then
  /bin/mkdir -m 700 "$build_root"
  created_build_root=1
fi
[[ -d "$build_root" && ! -L "$build_root" ]] ||
  fail "self-test build root is not a regular directory"
build_root_identity="$(path_identity "$build_root")" ||
  fail "self-test build root identity is unavailable"
/bin/mkdir -m 700 "$harness_root"
created_harness_root=1
harness_root_identity="$(path_identity "$harness_root")" ||
  fail "self-test harness identity is unavailable"
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
  ARKHAM_REPLAY_EXPECTED_CONTRACT_REVISION="$current_contract_revision" \
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

# Xcode code-signature requirement. Fixtures are tiny or already installed;
# nothing copies Xcode.
launcher_requirement=""
requirement_definitions=0
requirement_uses=0
codesign_requirements=0
while IFS= read -r launcher_line; do
  if [[ "$launcher_line" == "$xcode_signature_requirement_prefix"* ]]; then
    requirement_definitions=$((requirement_definitions + 1))
    launcher_requirement="${launcher_line#"$xcode_signature_requirement_prefix"}"
    launcher_requirement="${launcher_requirement%\'}"
  fi
  if [[ "$launcher_line" == *"-R="* ]]; then
    codesign_requirements=$((codesign_requirements + 1))
  fi
  # shellcheck disable=SC2016 # Match the launcher's literal source text.
  if [[ "$launcher_line" == *'-R="$xcode_signature_requirement"'* ]]; then
    requirement_uses=$((requirement_uses + 1))
  fi
done <"$production_launcher"
readonly launcher_requirement
[[ "$requirement_definitions" == 1 ]] ||
  fail "launcher must define xcode_signature_requirement exactly once"
[[ "$launcher_requirement" == "$expected_xcode_signature_requirement" ]] ||
  fail "launcher Xcode signature requirement is not the audited requirement: $launcher_requirement"
[[ "$codesign_requirements" == 1 && "$requirement_uses" == 1 ]] ||
  fail "launcher must verify Xcode against xcode_signature_requirement only"
[[ "$launcher_requirement" == *"$xcode_identifier_clause" ]] ||
  fail "launcher Xcode signature requirement does not end with the Xcode identifier"
readonly anchor_requirement="${launcher_requirement%"$xcode_identifier_clause"}"
printf 'PASS: launcher pins the audited Xcode signature requirement\n'

xcode_channel="Apple direct"
if [[ -e "$xcode_application/Contents/_MASReceipt" ]]; then
  xcode_channel="Mac App Store"
fi
expect_signature_verdict 0 "$launcher_requirement" "$xcode_application" \
  "launcher signature requirement rejected the installed $xcode_channel Xcode"
printf 'PASS: launcher signature requirement accepts the installed Xcode (%s channel, leaf %s)\n' \
  "$xcode_channel" \
  "$(leaf_signing_authority "$xcode_application")"

/bin/mkdir -p "$adhoc_xcode_fixture/Contents/MacOS"
/bin/cp -X /usr/bin/true "$adhoc_xcode_fixture/Contents/MacOS/Xcode"
/bin/cat >"$adhoc_xcode_fixture/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>Xcode</string>
  <key>CFBundleIdentifier</key>
  <string>com.apple.dt.Xcode</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
</dict>
</plist>
EOF
if ! /usr/bin/codesign --force --sign - --identifier com.apple.dt.Xcode \
  "$adhoc_xcode_fixture" >"$signature_log" 2>&1
then
  /bin/cat "$signature_log" >&2
  fail "ad-hoc Xcode fixture could not be signed"
fi
adhoc_details="$(
  /usr/bin/codesign -d --verbose=2 "$adhoc_xcode_fixture" 2>&1
)" || fail "ad-hoc Xcode fixture signature is unreadable"
readonly adhoc_details
if ! /usr/bin/grep -Fqx 'Identifier=com.apple.dt.Xcode' <<<"$adhoc_details" ||
  ! /usr/bin/grep -Fqx 'Signature=adhoc' <<<"$adhoc_details"
then
  fail "ad-hoc Xcode fixture is not an ad-hoc com.apple.dt.Xcode signature"
fi
expect_signature_verdict 3 "$launcher_requirement" "$adhoc_xcode_fixture" \
  "launcher signature requirement accepted an ad-hoc com.apple.dt.Xcode copy"
expect_signature_verdict 3 "$anchor_requirement" "$adhoc_xcode_fixture" \
  "launcher anchor clause accepted an ad-hoc signature"
printf 'PASS: launcher signature requirement rejects an ad-hoc re-signed com.apple.dt.Xcode copy\n'

[[ -d "$apple_platform_application" ]] ||
  fail "Apple platform application fixture is missing: $apple_platform_application"
expect_signature_verdict 0 "$anchor_requirement" "$apple_platform_application" \
  "launcher anchor clause rejected Apple-signed $apple_platform_application"
expect_signature_verdict 3 "$launcher_requirement" "$apple_platform_application" \
  "launcher signature requirement accepted a non-Xcode Apple application"
printf 'PASS: Apple-signed %s satisfies the anchor clause but not the Xcode identifier\n' \
  "$apple_platform_application"

select_signed_application app-store /Applications/*.app
readonly mas_application="$selected_application"
if [[ -n "$mas_application" ]]; then
  expect_signature_verdict 0 "$anchor_requirement" "$mas_application" \
    "launcher anchor clause rejected Mac App Store application $mas_application"
  expect_signature_verdict 3 "$launcher_requirement" "$mas_application" \
    "launcher signature requirement accepted non-Xcode Mac App Store application $mas_application"
  printf 'PASS: Mac App Store %s satisfies the anchor clause but not the Xcode identifier\n' \
    "$mas_application"
else
  printf 'SKIP: no verifiable Mac App Store application not signed as com.apple.dt.Xcode under /Applications\n'
fi

select_signed_application developer-id /Applications/*.app
readonly developer_id_application="$selected_application"
if [[ -n "$developer_id_application" ]]; then
  expect_signature_verdict 3 "$anchor_requirement" "$developer_id_application" \
    "launcher anchor clause accepted Developer ID application $developer_id_application"
  expect_signature_verdict 3 "$launcher_requirement" "$developer_id_application" \
    "launcher signature requirement accepted Developer ID application $developer_id_application"
  printf 'PASS: launcher anchor clause rejects Developer ID %s\n' \
    "$developer_id_application"
else
  printf 'SKIP: no verifiable Developer ID application not signed as com.apple.dt.Xcode under /Applications\n'
fi

for replay_scenario in \
  gathering-act-advance \
  gathering-cellar-entry \
  gathering-attic-entry
do
  if ARKHAM_REPLAY_SCENARIO="$replay_scenario" \
    ARKHAM_REPLAY_BASE_URL="https://example.com" \
    ARKHAM_REPLAY_INVESTIGATOR_ID="c01234" \
    ARKHAM_REPLAY_EXPECTED_APPLE_REVISION="0000000000000000000000000000000000000000" \
    ARKHAM_REPLAY_EXPECTED_CONTRACT_REVISION="$current_contract_revision" \
    ARKHAM_REPLAY_EXPECTED_CATALOG_REVISION="1.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
    "$production_launcher" \
    "$harness_root/checkpoint" \
    "$harness_root/output" \
    "$harness_root/token" \
    >"$revision_log" 2>&1
  then
    fail "production launcher accepted the wrong audited Apple revision for $replay_scenario"
  fi
  /usr/bin/grep -F \
    "trusted repository HEAD does not match the audited Apple revision" \
    "$revision_log" >/dev/null ||
    fail "production launcher did not reject the wrong Apple revision for $replay_scenario"
done
printf 'PASS: production accepts every Gathering scenario and requires the audited revision\n'

if ARKHAM_REPLAY_SCENARIO="future-replay" \
  ARKHAM_REPLAY_BASE_URL="https://example.com" \
  ARKHAM_REPLAY_INVESTIGATOR_ID="c01234" \
  ARKHAM_REPLAY_ENEMY_ID="00000000-0000-0000-0000-000000000301" \
  ARKHAM_REPLAY_EXPECTED_APPLE_REVISION="$audited_revision" \
  ARKHAM_REPLAY_EXPECTED_CONTRACT_REVISION="$current_contract_revision" \
  ARKHAM_REPLAY_EXPECTED_CATALOG_REVISION="1.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
  "$production_launcher" \
  "$harness_root/checkpoint" \
  "$harness_root/output" \
  "$harness_root/token" \
  >"$scenario_log" 2>&1
then
  fail "production launcher accepted an unknown replay scenario"
fi
/usr/bin/grep -F \
  "ARKHAM_REPLAY_SCENARIO is invalid" \
  "$scenario_log" >/dev/null ||
  fail "production launcher did not reject an unknown scenario explicitly"
printf 'PASS: production rejects unknown replay scenarios\n'

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
  ARKHAM_REPLAY_EXPECTED_CONTRACT_REVISION="$current_contract_revision" \
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
  ARKHAM_REPLAY_EXPECTED_CONTRACT_REVISION="$current_contract_revision" \
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
ignored_derived_data_root_identity="$(
  path_identity "$ignored_derived_data_root"
)" || fail "ignored source fixture parent identity is unavailable"
[[ ! -e "$ignored_source_root" && ! -L "$ignored_source_root" ]] ||
  fail "ignored source fixture path already exists"
/bin/mkdir -m 700 "$ignored_source_root"
created_ignored_source_root=1
ignored_source_root_identity="$(path_identity "$ignored_source_root")" ||
  fail "ignored source fixture identity is unavailable"
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
  ARKHAM_REPLAY_SCENARIO="gathering-act-advance" \
  ARKHAM_REPLAY_BASE_URL="http://example.com" \
  ARKHAM_REPLAY_INVESTIGATOR_ID="c01234" \
  ARKHAM_REPLAY_EXPECTED_APPLE_REVISION="$audited_revision" \
  ARKHAM_REPLAY_EXPECTED_CONTRACT_REVISION="$current_contract_revision" \
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
