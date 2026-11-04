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
readonly tampered_xcode_fixture="$harness_root/signature-tampered/Xcode.app"
readonly selfsigned_root="$harness_root/selfsigned"
readonly selfsigned_keychain="$selfsigned_root/replay-selftest.keychain-db"
readonly selfsigned_xcode_fixture="$selfsigned_root/Xcode.app"
readonly selfsigned_log="$selfsigned_root/keychain.log"
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
created_selfsigned_keychain=0
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
# is valid, or to "" when none qualifies. Cheap signature metadata is checked
# first; each remaining candidate gets one deep verify against the launcher's
# anchor clause:
#   kind          exit 0             exit 1           exit 3             other
#   app-store     select             skip (invalid)   FAIL               FAIL
#   developer-id  FAIL               skip (invalid)   select             FAIL
# so a selected app has already proven its anchor-clause verdict.
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
    /usr/bin/codesign --verify --deep --strict \
      -R="$anchor_requirement" \
      "$candidate" \
      >"$signature_log" 2>&1 || status=$?
    case "$kind:$status" in
      app-store:0 | developer-id:3)
        selected_application="$candidate"
        return 0
        ;;
      *:1)
        printf 'note: skipping %s: its signature does not verify (codesign exit 1)\n' \
          "$candidate"
        continue
        ;;
      app-store:3)
        /bin/cat "$signature_log" >&2
        fail "anchor clause rejected an App Store Xcode-family app: $candidate"
        ;;
      developer-id:0)
        /bin/cat "$signature_log" >&2
        fail "anchor clause accepted Developer ID: $candidate"
        ;;
      *)
        /bin/cat "$signature_log" >&2
        fail "unexpected anchor-clause verdict for $kind application $candidate (codesign exit $status)"
        ;;
    esac
  done
  return 0
}

# Runs a command that could block on a keychain or key-access prompt. macOS
# has no timeout(1), so perl arms SIGALRM and execs the command; after
# keychain_step_timeout seconds the command dies with exit 142 (128 + SIGALRM),
# which fails the self-test naming the step. Otherwise it returns the
# command's own exit status.
readonly keychain_step_timeout=120
bounded() {
  local step="$1"
  shift
  local status=0
  /usr/bin/perl -e 'alarm shift; exec @ARGV or die "exec failed: $!\n"' \
    "$keychain_step_timeout" "$@" || status=$?
  if [[ "$status" == 142 ]]; then
    fail "$step timed out after ${keychain_step_timeout}s (a keychain or key-access prompt may be waiting)"
  fi
  return "$status"
}

# Prints the user keychain search list, one path per line.
user_keychain_search_list() {
  local listing
  listing="$(/usr/bin/security list-keychains -d user)" || return 1
  /usr/bin/sed -n 's/^[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' <<<"$listing"
}

# Succeeds only when the user search list is readable and does not contain
# the self-test keychain.
selfsigned_keychain_search_status() {
  local listing
  listing="$(user_keychain_search_list)" || return 1
  ! /usr/bin/grep -Fqx -- "$selfsigned_keychain" <<<"$listing"
}

# Removes only the self-test keychain's entry from the user search list. It
# never restores a snapshot and never sets an empty list.
remove_selfsigned_keychain_from_search_list() {
  local listing entry found=0
  local -a remaining=()
  listing="$(user_keychain_search_list)" ||
    fail "user keychain search list is unavailable"
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    if [[ "$entry" == "$selfsigned_keychain" ]]; then
      found=1
    else
      remaining+=("$entry")
    fi
  done <<<"$listing"
  [[ "$found" == 1 ]] || return 0
  if [[ "${#remaining[@]}" == 0 ]]; then
    printf 'note: the self-test keychain is the only user search-list entry; delete-keychain removes it\n'
    return 0
  fi
  /usr/bin/security list-keychains -d user -s "${remaining[@]}" ||
    fail "could not remove the self-test keychain from the user search list"
}

# Appends only the self-test keychain to the current user search list.
append_selfsigned_keychain_to_search_list() {
  local listing entry
  local -a entries=()
  listing="$(user_keychain_search_list)" ||
    fail "user keychain search list is unavailable"
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    entries+=("$entry")
  done <<<"$listing"
  entries+=("$selfsigned_keychain")
  /usr/bin/security list-keychains -d user -s "${entries[@]}" ||
    fail "could not add the self-test keychain to the user search list"
}

sign_selfsigned_fixture() {
  bounded "signing the fixture with codesign" \
    /usr/bin/codesign --force \
    --sign "$selfsigned_fingerprint" \
    --keychain "$selfsigned_keychain" \
    --identifier com.apple.dt.Xcode \
    --timestamp=none \
    "$selfsigned_xcode_fixture" \
    >"$selfsigned_log" 2>&1
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

  if [[ "$created_selfsigned_keychain" == 1 &&
    -n "$selfsigned_keychain" &&
    "$selfsigned_keychain" == "$harness_root/"* ]]
  then
    if ! /usr/bin/security delete-keychain "$selfsigned_keychain" >/dev/null 2>&1; then
      printf 'FAIL: could not delete self-test keychain %s\n' "$selfsigned_keychain" >&2
      cleanup_failed=1
    fi
    if ! selfsigned_keychain_search_status; then
      printf 'FAIL: self-test keychain may still be in the user search list\n' >&2
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

# A damaged bundle must be reported as an invalid signature (exit 1), which
# select_signed_application skips, not as a requirement mismatch (exit 3).
/bin/mkdir -p "$(/usr/bin/dirname -- "$tampered_xcode_fixture")"
/bin/cp -R "$adhoc_xcode_fixture" "$tampered_xcode_fixture"
printf 'x' >>"$tampered_xcode_fixture/Contents/MacOS/Xcode"
expect_signature_verdict 1 "$anchor_requirement" "$tampered_xcode_fixture" \
  "a damaged com.apple.dt.Xcode bundle was not reported as an invalid signature"
printf 'PASS: a damaged signed bundle is an invalid signature (exit 1), not a requirement mismatch\n'

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
  # Selection already proved the anchor clause holds (codesign exit 0).
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
  # Selection already proved the anchor clause rejects it (codesign exit 3).
  expect_signature_verdict 3 "$launcher_requirement" "$developer_id_application" \
    "launcher signature requirement accepted Developer ID application $developer_id_application"
  printf 'PASS: launcher anchor clause rejects Developer ID %s\n' \
    "$developer_id_application"
else
  printf 'SKIP: no verifiable Developer ID application not signed as com.apple.dt.Xcode under /Applications\n'
fi

# A throwaway self-signed certificate carrying the Mac App Store leaf OID
# (1.2.840.113635.100.6.1.9). The leaf-OID and identifier clauses alone accept
# it (positive control), so only `anchor apple generic` keeps the App Store
# clause from accepting a self-made certificate: the anchor clause and the full
# requirement must reject it with exit 3. Signing needs a temporary keychain,
# which touches the user keychain search list, so this runs by default only in
# GitHub Actions. Locally it is skipped unless ARKHAM_SELFTEST_KEYCHAIN=1. When
# it runs, every problem (missing tools included) is a failure. It never adds
# trust settings or touches the System keychain.
readonly leaf_oid_clause='certificate leaf[field.1.2.840.113635.100.6.1.9]'
readonly selfsigned_common_name='ArkhamHorror replay self-test (untrusted)'
selfsigned_fingerprint=""
if [[ "${GITHUB_ACTIONS:-}" != true && "${ARKHAM_SELFTEST_KEYCHAIN:-}" != 1 ]]; then
  printf 'SKIP: self-signed leaf-OID keychain scenario runs only in GitHub Actions or with ARKHAM_SELFTEST_KEYCHAIN=1\n'
else
  for keychain_tool in /usr/bin/openssl /usr/bin/security /usr/bin/codesign; do
    [[ -x "$keychain_tool" ]] ||
      fail "self-signed keychain scenario requires $keychain_tool"
  done
  [[ "$launcher_requirement" == *"$leaf_oid_clause"* &&
    "$launcher_requirement" == *"$xcode_identifier_clause" ]] ||
    fail "launcher requirement no longer contains the leaf-OID and identifier clauses"
  /bin/mkdir -m 700 "$selfsigned_root"
  /bin/cat >"$selfsigned_root/openssl.cnf" <<EOF
[req]
distinguished_name = selftest_dn
x509_extensions = selftest_ext
prompt = no

[selftest_dn]
CN = $selfsigned_common_name

[selftest_ext]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
1.2.840.113635.100.6.1.9 = ASN1:NULL
EOF
  if ! /usr/bin/openssl req -x509 -new -newkey rsa:2048 -nodes -sha256 -days 1 \
    -config "$selfsigned_root/openssl.cnf" \
    -keyout "$selfsigned_root/key.pem" \
    -out "$selfsigned_root/cert.pem" \
    >"$selfsigned_log" 2>&1
  then
    /bin/cat "$selfsigned_log" >&2
    fail "could not create the self-signed certificate"
  fi
  selfsigned_text="$(
    /usr/bin/openssl x509 -in "$selfsigned_root/cert.pem" -noout -text
  )" || fail "self-signed certificate is unreadable"
  /usr/bin/grep -Fq '1.2.840.113635.100.6.1.9' <<<"$selfsigned_text" ||
    fail "self-signed certificate does not carry OID 1.2.840.113635.100.6.1.9"
  selfsigned_fingerprint="$(
    /usr/bin/openssl x509 -in "$selfsigned_root/cert.pem" -noout -fingerprint -sha1
  )" || fail "self-signed certificate fingerprint is unavailable"
  selfsigned_fingerprint="${selfsigned_fingerprint#*=}"
  selfsigned_fingerprint="${selfsigned_fingerprint//:/}"
  [[ "$selfsigned_fingerprint" =~ ^[0-9A-F]{40}$ ]] ||
    fail "self-signed certificate fingerprint is malformed"
  pkcs12_password="$(/usr/bin/openssl rand -hex 24)"
  keychain_password="$(/usr/bin/openssl rand -hex 24)"
  if [[ "$(/usr/bin/openssl version)" == LibreSSL* ]]; then
    pkcs12_status=0
    /usr/bin/openssl pkcs12 -export \
      -inkey "$selfsigned_root/key.pem" \
      -in "$selfsigned_root/cert.pem" \
      -name "$selfsigned_common_name" \
      -passout "pass:$pkcs12_password" \
      -out "$selfsigned_root/identity.p12" \
      >"$selfsigned_log" 2>&1 || pkcs12_status=$?
  else
    pkcs12_status=0
    /usr/bin/openssl pkcs12 -export -legacy \
      -inkey "$selfsigned_root/key.pem" \
      -in "$selfsigned_root/cert.pem" \
      -name "$selfsigned_common_name" \
      -passout "pass:$pkcs12_password" \
      -out "$selfsigned_root/identity.p12" \
      >"$selfsigned_log" 2>&1 || pkcs12_status=$?
  fi
  if [[ "$pkcs12_status" != 0 ]]; then
    /bin/cat "$selfsigned_log" >&2
    fail "could not export the self-signed identity"
  fi

  search_list_before="$(user_keychain_search_list)" ||
    fail "user keychain search list is unavailable"
  default_keychain_before="$(/usr/bin/security default-keychain -d user)" ||
    fail "user default keychain is unavailable"
  [[ ! -e "$selfsigned_keychain" ]] ||
    fail "self-test keychain path already exists"
  keychain_status=0
  bounded "security create-keychain" \
    /usr/bin/security create-keychain -p "$keychain_password" \
    "$selfsigned_keychain" >"$selfsigned_log" 2>&1 || keychain_status=$?
  if [[ "$keychain_status" == 0 || -e "$selfsigned_keychain" ]]; then
    created_selfsigned_keychain=1
  fi
  if [[ "$keychain_status" != 0 ]]; then
    /bin/cat "$selfsigned_log" >&2
    fail "could not create the self-test keychain"
  fi
  [[ -f "$selfsigned_keychain" ]] ||
    fail "self-test keychain was not created at $selfsigned_keychain"
  remove_selfsigned_keychain_from_search_list
  [[ "$(user_keychain_search_list)" == "$search_list_before" ]] ||
    fail "creating the self-test keychain changed the user search list beyond its own entry"
  [[ "$(/usr/bin/security default-keychain -d user)" == "$default_keychain_before" ]] ||
    fail "creating the self-test keychain changed the user default keychain"
  for keychain_step in settings unlock import partition; do
    keychain_status=0
    case "$keychain_step" in
      settings)
        bounded "security set-keychain-settings" \
          /usr/bin/security set-keychain-settings "$selfsigned_keychain" \
          >"$selfsigned_log" 2>&1 || keychain_status=$?
        ;;
      unlock)
        bounded "security unlock-keychain" \
          /usr/bin/security unlock-keychain -p "$keychain_password" \
          "$selfsigned_keychain" >"$selfsigned_log" 2>&1 || keychain_status=$?
        ;;
      import)
        bounded "security import" \
          /usr/bin/security import "$selfsigned_root/identity.p12" \
          -k "$selfsigned_keychain" \
          -f pkcs12 \
          -P "$pkcs12_password" \
          -T /usr/bin/codesign \
          >"$selfsigned_log" 2>&1 || keychain_status=$?
        ;;
      partition)
        bounded "security set-key-partition-list" \
          /usr/bin/security set-key-partition-list \
          -S apple-tool:,apple:,codesign: \
          -s \
          -k "$keychain_password" \
          "$selfsigned_keychain" \
          >"$selfsigned_log" 2>&1 || keychain_status=$?
        /usr/bin/sed 's/^/  set-key-partition-list: /' "$selfsigned_log"
        ;;
    esac
    if [[ "$keychain_status" != 0 ]]; then
      /bin/cat "$selfsigned_log" >&2
      fail "self-test keychain step '$keychain_step' failed (exit $keychain_status)"
    fi
  done

  /bin/cp -R "$adhoc_xcode_fixture" "$selfsigned_xcode_fixture"
  if ! sign_selfsigned_fixture; then
    if [[ "${GITHUB_ACTIONS:-}" == true ]] &&
      /usr/bin/grep -Fq 'no identity found' "$selfsigned_log" &&
      selfsigned_keychain_search_status
    then
      printf 'note: codesign --keychain did not find the identity off the search list; retrying with only the self-test keychain appended\n'
      append_selfsigned_keychain_to_search_list
      sign_status=0
      sign_selfsigned_fixture || sign_status=$?
      remove_selfsigned_keychain_from_search_list
      [[ "$(user_keychain_search_list)" == "$search_list_before" ]] ||
        fail "user search list was not restored after the temporary self-test keychain entry"
      if [[ "$sign_status" != 0 ]]; then
        /bin/cat "$selfsigned_log" >&2
        fail "could not sign the fixture with the self-signed identity"
      fi
    else
      /bin/cat "$selfsigned_log" >&2
      fail "could not sign the fixture with the self-signed identity"
    fi
  fi
  selfsigned_details="$(
    /usr/bin/codesign -d --verbose=2 "$selfsigned_xcode_fixture" 2>&1
  )" || fail "self-signed fixture signature is unreadable"
  /usr/bin/grep -Fqx 'Identifier=com.apple.dt.Xcode' <<<"$selfsigned_details" ||
    fail "self-signed fixture is not signed as com.apple.dt.Xcode"
  [[ "$(leaf_signing_authority "$selfsigned_xcode_fixture")" == "$selfsigned_common_name" ]] ||
    fail "self-signed fixture's leaf authority is not the self-test certificate"
  if /usr/bin/grep -Fqx 'Signature=adhoc' <<<"$selfsigned_details"; then
    fail "self-signed fixture is still ad-hoc signed"
  fi

  verify_status=0
  /usr/bin/codesign --verify --deep --strict "$selfsigned_xcode_fixture" \
    >"$signature_log" 2>&1 || verify_status=$?
  if [[ "$verify_status" != 0 ]]; then
    /bin/cat "$signature_log" >&2
    fail "self-signed fixture signature does not verify (codesign exit $verify_status)"
  fi
  expect_signature_verdict 0 "${leaf_oid_clause}${xcode_identifier_clause}" \
    "$selfsigned_xcode_fixture" \
    "positive control: the leaf-OID and identifier clauses rejected the self-signed fixture"
  expect_signature_verdict 3 "$anchor_requirement" "$selfsigned_xcode_fixture" \
    "launcher anchor clause accepted a self-signed certificate carrying the App Store leaf OID"
  expect_signature_verdict 3 "$launcher_requirement" "$selfsigned_xcode_fixture" \
    "launcher signature requirement accepted a self-signed com.apple.dt.Xcode signature carrying the App Store leaf OID"

  if ! bounded "security delete-keychain" \
    /usr/bin/security delete-keychain "$selfsigned_keychain" \
    >"$selfsigned_log" 2>&1
  then
    /bin/cat "$selfsigned_log" >&2
    fail "could not delete the self-test keychain"
  fi
  created_selfsigned_keychain=0
  [[ ! -e "$selfsigned_keychain" ]] ||
    fail "self-test keychain file survived delete-keychain"
  selfsigned_keychain_search_status ||
    fail "self-test keychain is still in the user search list"
  [[ "$(/usr/bin/security default-keychain -d user)" == "$default_keychain_before" ]] ||
    fail "user default keychain changed during the self-signed scenario"
  printf 'PASS: anchor apple generic rejects a self-signed com.apple.dt.Xcode signature carrying the App Store leaf OID\n'
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
