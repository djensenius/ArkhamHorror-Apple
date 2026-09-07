#!/bin/sh
# Offline self-test harness for `verify-locale-digest-provenance.sh`.
#
# The real script's job (fetching the pinned upstream web-client commit over the network)
# is deliberately network-dependent and therefore excluded from `mise run test`'s offline
# suite (see the `locale-digest-provenance` mise task). That still leaves the script's
# *own* logic -- symlink rejection, git index/tree mode checks, and local directory-set
# agreement -- entirely untested by anything else in this repo. Mirrors
# `Scripts/test-verify-contract-fixture-provenance.sh`'s own pattern.
#
# This harness exercises that logic end to end, fully offline: it builds two disposable
# scratch git repositories (one standing in for "the local vendored raw fixtures", one
# standing in for "the pinned upstream commit"), points `verify-locale-digest-provenance.sh`
# at them via its `LOCALE_PROVENANCE_*` environment overrides (see that script's own header
# comment), and asserts each scenario's exit code and diagnostic output. It never touches
# the real vendored fixtures, `LocaleDigestFixtureProvenance.swift`, or the network.
set -eu

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
script_under_test="$repo_root/Scripts/verify-locale-digest-provenance.sh"
# A scratch directory under the repository's own (gitignored) `.build/`, never `/tmp`.
harness_root="$repo_root/.build/locale-digest-provenance-selftest"
real_provenance_file="$repo_root/Packages/ArkhamHorrorShared/Sources/ArkhamHorrorShared/Domain/Asset/LocaleDigestFixtureProvenance.swift"

fixture_names="it.json fr.json es.json ko.json zh.json"

failures=0
scenario_count=0

# Runs the script under test with the given `LOCALE_PROVENANCE_*` overrides layered onto a
# fresh scratch checkout directory (so scenarios never interfere with each other's
# checkouts), capturing its combined output and exit code without ever letting `set -e`
# abort the harness on an *expected* failure.
run_script() {
  local_fixture_dir="$1"
  upstream_repo="$2"
  upstream_commit="$3"
  scratch_dir="$harness_root/checkout-$scenario_count"
  rm -rf "$scratch_dir"
  set +e
  script_output=$(
    LOCALE_PROVENANCE_REPO_ROOT="$local_repo" \
    LOCALE_PROVENANCE_LOCAL_FIXTURE_DIR="$local_fixture_dir" \
    LOCALE_PROVENANCE_FILE="$real_provenance_file" \
    LOCALE_PROVENANCE_REPO_URL="$upstream_repo" \
    LOCALE_PROVENANCE_COMMIT="$upstream_commit" \
    LOCALE_PROVENANCE_SCRATCH_DIR="$scratch_dir" \
    "$script_under_test" 2>&1
  )
  script_exit=$?
  set -e
}

# Asserts the most recently captured `script_output`/`script_exit` matches an expected
# outcome, reporting a harness-level failure (not exiting immediately) so every scenario
# still runs even if an earlier one regresses.
assert_outcome() {
  description="$1"
  expected_exit="$2"
  expected_output_substring="$3"
  scenario_count=$((scenario_count + 1))
  if [ "$script_exit" != "$expected_exit" ]; then
    echo "FAIL [$description]: expected exit $expected_exit, got $script_exit" >&2
    echo "--- captured output ---" >&2
    echo "$script_output" >&2
    echo "------------------------" >&2
    failures=$((failures + 1))
    return
  fi
  if [ -n "$expected_output_substring" ]; then
    case "$script_output" in
      *"$expected_output_substring"*) ;;
      *)
        echo "FAIL [$description]: expected output to contain '$expected_output_substring'" >&2
        echo "--- captured output ---" >&2
        echo "$script_output" >&2
        echo "------------------------" >&2
        failures=$((failures + 1))
        return
        ;;
    esac
  fi
  echo "PASS [$description]"
}

# --- Build the disposable "upstream" scratch repository -----------------------------------
#
# Stands in for the pinned upstream `djensenius/ArkhamHorror` commit. `git fetch --depth 1`
# works perfectly well against a plain local path, so no network or bare-repo ceremony is
# needed.
upstream_repo="$harness_root/upstream"
rm -rf "$upstream_repo"
mkdir -p "$upstream_repo/frontend/src/digests"
git init -q "$upstream_repo"
git -C "$upstream_repo" config user.email "test@example.com"
git -C "$upstream_repo" config user.name "Provenance Test"
# The real upstream, GitHub, already permits fetching an arbitrary reachable commit SHA
# (not only refs) for public repositories -- this harness's local scratch "upstream" needs
# the equivalent permission explicitly, scoped to only this disposable repository (never
# globally), so `run_script`'s `git fetch --depth 1 origin <sha>` behaves the same way here
# as it does against the real upstream repository.
git -C "$upstream_repo" config uploadpack.allowReachableSHA1InWant true

write_upstream_digest() {
  name="$1"
  echo "[\"cards/$name-placeholder.avif\"]" >"$upstream_repo/frontend/src/digests/$name"
}

write_upstream_digest ita.json
write_upstream_digest fr.json
write_upstream_digest es.json
write_upstream_digest ko.json
write_upstream_digest zh.json
git -C "$upstream_repo" add -A
git -C "$upstream_repo" commit -q -m "good upstream state"
good_upstream_commit=$(git -C "$upstream_repo" rev-parse HEAD)

# A second upstream commit where one digest's blob mode is executable (100755) instead of
# the expected regular 100644 -- exercises `assert_upstream_path_is_regular_blob`.
chmod +x "$upstream_repo/frontend/src/digests/es.json"
git -C "$upstream_repo" add -A
git -C "$upstream_repo" commit -q -m "es.json wrongly executable"
wrong_mode_upstream_commit=$(git -C "$upstream_repo" rev-parse HEAD)
chmod -x "$upstream_repo/frontend/src/digests/es.json"
git -C "$upstream_repo" add -A
git -C "$upstream_repo" commit -q -m "restore es.json mode"

# --- Build the disposable "local" scratch repository -------------------------------------
#
# Stands in for this repository's own vendored `Fixtures/LocaleDigests/raw` directory and
# its own git index (used by `assert_local_path_is_regular_index_entry`).
local_repo="$harness_root/local"
rm -rf "$local_repo"
local_fixture_dir="$local_repo/Fixtures/LocaleDigests/raw"
mkdir -p "$local_fixture_dir"
git init -q "$local_repo"
git -C "$local_repo" config user.email "test@example.com"
git -C "$local_repo" config user.name "Provenance Test"

reset_local_good_state() {
  rm -rf "$local_fixture_dir"
  mkdir -p "$local_fixture_dir"
  cp "$upstream_repo/frontend/src/digests/ita.json" "$local_fixture_dir/it.json"
  cp "$upstream_repo/frontend/src/digests/fr.json" "$local_fixture_dir/fr.json"
  cp "$upstream_repo/frontend/src/digests/es.json" "$local_fixture_dir/es.json"
  cp "$upstream_repo/frontend/src/digests/ko.json" "$local_fixture_dir/ko.json"
  cp "$upstream_repo/frontend/src/digests/zh.json" "$local_fixture_dir/zh.json"
  rm -rf "$local_repo/.git"
  git init -q "$local_repo"
  git -C "$local_repo" config user.email "test@example.com"
  git -C "$local_repo" config user.name "Provenance Test"
  git -C "$local_repo" add -A
  git -C "$local_repo" commit -q -m "vendor good state"
}

echo "=== Scenario: byte-identical, correctly tracked fixtures (expect PASS) ==="
reset_local_good_state
run_script "$local_fixture_dir" "$upstream_repo" "$good_upstream_commit"
assert_outcome "all good" 0 "All governed raw locale digest fixtures match upstream commit"

echo "=== Scenario: local symlink standing in for identical bytes (expect FAIL) ==="
reset_local_good_state
real_target="$local_repo/es-real-target.json"
cp "$local_fixture_dir/es.json" "$real_target"
rm "$local_fixture_dir/es.json"
ln -s "$real_target" "$local_fixture_dir/es.json"
run_script "$local_fixture_dir" "$upstream_repo" "$good_upstream_commit"
assert_outcome "local symlink-to-identical-bytes" 1 "is a symlink, not a regular vendored fixture file"

echo "=== Scenario: extra unregistered local file (expect FAIL) ==="
reset_local_good_state
echo '["unexpected"]' >"$local_fixture_dir/unexpected.json"
run_script "$local_fixture_dir" "$upstream_repo" "$good_upstream_commit"
assert_outcome "extra local file" 1 "does not exactly match this script's governed path map"

echo "=== Scenario: missing local file (expect FAIL) ==="
reset_local_good_state
rm "$local_fixture_dir/zh.json"
git -C "$local_repo" add -A
git -C "$local_repo" commit -q -m "accidentally drop zh.json"
run_script "$local_fixture_dir" "$upstream_repo" "$good_upstream_commit"
assert_outcome "missing local file" 1 "does not exactly match this script's governed path map"

echo "=== Scenario: local file tracked at the wrong git index mode (expect FAIL) ==="
reset_local_good_state
chmod +x "$local_fixture_dir/fr.json"
git -C "$local_repo" add -A
git -C "$local_repo" commit -q -m "wrongly mark fr.json executable"
run_script "$local_fixture_dir" "$upstream_repo" "$good_upstream_commit"
assert_outcome "wrong local index mode" 1 "is tracked at mode 100755, not the expected regular 100644"

echo "=== Scenario: altered local bytes (expect FAIL) ==="
reset_local_good_state
echo '["tampered"]' >"$local_fixture_dir/es.json"
git -C "$local_repo" add -A
git -C "$local_repo" commit -q -m "tamper with es.json"
run_script "$local_fixture_dir" "$upstream_repo" "$good_upstream_commit"
assert_outcome "altered local bytes" 1 "differs from frontend/src/digests/es.json"

echo "=== Scenario: upstream blob at the wrong mode (expect FAIL) ==="
reset_local_good_state
run_script "$local_fixture_dir" "$upstream_repo" "$wrong_mode_upstream_commit"
assert_outcome "wrong upstream blob mode" 1 "is not a regular (100644) blob"

rm -rf "$harness_root"

echo ""
echo "$scenario_count scenario(s) run, $failures failed."
if [ "$failures" -ne 0 ]; then
  exit 1
fi
echo "All locale-digest provenance-script self-test scenarios behaved as expected."
