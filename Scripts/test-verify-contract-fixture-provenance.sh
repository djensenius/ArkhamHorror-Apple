#!/bin/sh
# Offline self-test harness for `verify-contract-fixture-provenance.sh`.
#
# The real script's job (fetching the pinned upstream backend commit over the network) is
# deliberately network-dependent and therefore excluded from `mise run test`'s offline
# suite (see the `contract-provenance` mise task). That still leaves the script's *own*
# logic -- symlink rejection, git index/tree mode checks, local directory-set agreement,
# and backend-manifest cross-validation -- entirely untested by anything else in this repo.
#
# This harness exercises that logic end to end, fully offline: it builds two disposable
# scratch git repositories (one standing in for "the local vendored fixtures", one standing
# in for "the pinned backend commit"), points `verify-contract-fixture-provenance.sh` at
# them via its `PROVENANCE_*` environment overrides (see that script's own header comment),
# and asserts each scenario's exit code and diagnostic output. It never touches the real
# vendored fixtures, `ContractPin.swift`, or the network.
set -eu

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
script_under_test="$repo_root/Scripts/verify-contract-fixture-provenance.sh"
# A scratch directory under the repository's own (gitignored) `.build/`, never `/tmp`.
harness_root="$repo_root/.build/contract-fixture-provenance-selftest"
real_contract_pin_file="$repo_root/Packages/ArkhamHorrorShared/Sources/ArkhamHorrorShared/Domain/Contract/ContractPin.swift"

fixture_names="capabilities.json catalog.json decks.json game-lifecycle.json game-list.json \
get-game.json game-update.json mode-turn-zero.json mode-campaign-only.json \
mode-campaign-scenario.json location-enemy-view.json movement.json \
act-no-advance-cost.json investigator-unhealed-horror-negative.json \
uuid-entity-map.json card-code-entity-map.json question-choose-one.json \
question-player-window-choose-one.json question-window-choose-one.json \
answer-question.json question-read.json question-read-with-cards.json \
question-choose-one-location.json question-choose-one-location-multiple.json"

failures=0
scenario_count=0

# Runs the script under test with the given `PROVENANCE_*` overrides layered onto a fresh
# scratch checkout directory (so scenarios never interfere with each other's checkouts),
# capturing its combined output and exit code without ever letting `set -e` abort the
# harness on an *expected* failure.
run_script() {
  local_fixture_dir="$1"
  backend_repo="$2"
  backend_commit="$3"
  scratch_dir="$harness_root/checkout-$scenario_count"
  rm -rf "$scratch_dir"
  set +e
  script_output=$(
    PROVENANCE_REPO_ROOT="$local_repo" \
    PROVENANCE_LOCAL_FIXTURE_DIR="$local_fixture_dir" \
    PROVENANCE_CONTRACT_PIN_FILE="$real_contract_pin_file" \
    PROVENANCE_BACKEND_REPO_URL="$backend_repo" \
    PROVENANCE_BACKEND_COMMIT="$backend_commit" \
    PROVENANCE_SCRATCH_DIR="$scratch_dir" \
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

# --- Build the disposable "backend" scratch repository ----------------------------------
#
# Stands in for the pinned upstream `djensenius/ArkhamHorror` commit. `git fetch --depth 1`
# works perfectly well against a plain local path, so no network or bare-repo ceremony is
# needed.
backend_repo="$harness_root/backend"
rm -rf "$backend_repo"
mkdir -p "$backend_repo/contracts/fixtures"
git init -q "$backend_repo"
git -C "$backend_repo" config user.email "test@example.com"
git -C "$backend_repo" config user.name "Provenance Test"
# The real backend, GitHub, already permits fetching an arbitrary reachable commit SHA
# (not only refs) for public repositories -- this harness's local scratch "backend" needs
# the equivalent permission explicitly, scoped to only this disposable repository (never
# globally), so `run_script`'s `git fetch --depth 1 origin <sha>` behaves the same way here
# as it does against the real upstream repository.
git -C "$backend_repo" config uploadpack.allowReachableSHA1InWant true

write_backend_manifest() {
  target="$1"
  shift
  {
    echo '{'
    echo '  "schemaRevision": "0.1.22",'
    echo '  "fixtures": ['
    first=1
    for name in "$@"; do
      if [ "$first" -eq 0 ]; then echo ','; fi
      first=0
      printf '    {"path": "contracts/fixtures/%s"}' "$name"
    done
    echo ''
    echo '  ]'
    echo '}'
  } >"$target"
}

for name in $fixture_names; do
  echo "{\"fixture\": \"$name\", \"value\": 1}" >"$backend_repo/contracts/fixtures/$name"
done
# shellcheck disable=SC2086
write_backend_manifest "$backend_repo/contracts/manifest.json" $fixture_names
git -C "$backend_repo" add -A
git -C "$backend_repo" commit -q -m "good backend state"
good_backend_commit=$(git -C "$backend_repo" rev-parse HEAD)

# A second backend commit where one fixture's blob mode is executable (100755) instead of
# the expected regular 100644 -- exercises `assert_backend_path_is_regular_blob`.
chmod +x "$backend_repo/contracts/fixtures/catalog.json"
git -C "$backend_repo" add -A
git -C "$backend_repo" commit -q -m "catalog.json wrongly executable"
wrong_mode_backend_commit=$(git -C "$backend_repo" rev-parse HEAD)
chmod -x "$backend_repo/contracts/fixtures/catalog.json"
git -C "$backend_repo" add -A
git -C "$backend_repo" commit -q -m "restore catalog.json mode"

# A third backend commit whose manifest no longer lists decks.json as a fixture, even
# though the file itself is untouched -- exercises the manifest cross-validation.
write_backend_manifest "$backend_repo/contracts/manifest.json" \
  capabilities.json catalog.json game-lifecycle.json game-list.json
git -C "$backend_repo" add -A
git -C "$backend_repo" commit -q -m "manifest no longer lists decks.json"
unregistered_backend_commit=$(git -C "$backend_repo" rev-parse HEAD)
# shellcheck disable=SC2086
write_backend_manifest "$backend_repo/contracts/manifest.json" $fixture_names
git -C "$backend_repo" add -A
git -C "$backend_repo" commit -q -m "restore manifest fixture listing"

# --- Build the disposable "local" scratch repository -------------------------------------
#
# Stands in for this repository's own vendored `Fixtures/Contract` directory and its own
# git index (used by `assert_local_path_is_regular_index_entry`).
local_repo="$harness_root/local"
rm -rf "$local_repo"
local_fixture_dir="$local_repo/Fixtures/Contract"
mkdir -p "$local_fixture_dir"
git init -q "$local_repo"
git -C "$local_repo" config user.email "test@example.com"
git -C "$local_repo" config user.name "Provenance Test"

reset_local_good_state() {
  rm -rf "$local_fixture_dir"
  mkdir -p "$local_fixture_dir"
  for name in $fixture_names; do
    cp "$backend_repo/contracts/fixtures/$name" "$local_fixture_dir/$name"
  done
  write_backend_manifest "$local_fixture_dir/manifest.json" $fixture_names
  rm -rf "$local_repo/.git"
  git init -q "$local_repo"
  git -C "$local_repo" config user.email "test@example.com"
  git -C "$local_repo" config user.name "Provenance Test"
  git -C "$local_repo" add -A
  git -C "$local_repo" commit -q -m "vendor good state"
}

echo "=== Scenario: byte-identical, correctly tracked fixtures (expect PASS) ==="
reset_local_good_state
run_script "$local_fixture_dir" "$backend_repo" "$good_backend_commit"
assert_outcome "all good" 0 "All governed contract fixtures match backend commit"

echo "=== Scenario: local symlink standing in for identical bytes (expect FAIL) ==="
reset_local_good_state
real_target="$local_repo/catalog-real-target.json"
cp "$local_fixture_dir/catalog.json" "$real_target"
rm "$local_fixture_dir/catalog.json"
ln -s "$real_target" "$local_fixture_dir/catalog.json"
run_script "$local_fixture_dir" "$backend_repo" "$good_backend_commit"
assert_outcome "local symlink-to-identical-bytes" 1 "is a symlink, not a regular vendored fixture file"

echo "=== Scenario: extra unregistered local file (expect FAIL) ==="
reset_local_good_state
echo '{"unexpected": true}' >"$local_fixture_dir/unexpected.json"
run_script "$local_fixture_dir" "$backend_repo" "$good_backend_commit"
assert_outcome "extra local file" 1 "does not exactly match this script's governed path map"

echo "=== Scenario: missing local file (expect FAIL) ==="
reset_local_good_state
rm "$local_fixture_dir/game-list.json"
git -C "$local_repo" add -A
git -C "$local_repo" commit -q -m "accidentally drop game-list.json"
run_script "$local_fixture_dir" "$backend_repo" "$good_backend_commit"
assert_outcome "missing local file" 1 "does not exactly match this script's governed path map"

echo "=== Scenario: local file tracked at the wrong git index mode (expect FAIL) ==="
reset_local_good_state
chmod +x "$local_fixture_dir/decks.json"
git -C "$local_repo" add -A
git -C "$local_repo" commit -q -m "wrongly mark decks.json executable"
run_script "$local_fixture_dir" "$backend_repo" "$good_backend_commit"
assert_outcome "wrong local index mode" 1 "is tracked at mode 100755, not the expected regular 100644"

echo "=== Scenario: altered local bytes (expect FAIL) ==="
reset_local_good_state
echo '{"fixture": "catalog.json", "value": 999}' >"$local_fixture_dir/catalog.json"
git -C "$local_repo" add -A
git -C "$local_repo" commit -q -m "tamper with catalog.json"
run_script "$local_fixture_dir" "$backend_repo" "$good_backend_commit"
assert_outcome "altered local bytes" 1 "differs from contracts/fixtures/catalog.json"

echo "=== Scenario: backend blob at the wrong mode (expect FAIL) ==="
reset_local_good_state
run_script "$local_fixture_dir" "$backend_repo" "$wrong_mode_backend_commit"
assert_outcome "wrong backend blob mode" 1 "is not a regular (100644) blob"

echo "=== Scenario: backend manifest no longer lists a byte-identical fixture (expect FAIL) ==="
reset_local_good_state
run_script "$local_fixture_dir" "$backend_repo" "$unregistered_backend_commit"
assert_outcome "unregistered backend fixture" 1 "does not list it as a fixture"

rm -rf "$harness_root"

echo ""
echo "$scenario_count scenario(s) run, $failures failed."
if [ "$failures" -ne 0 ]; then
  exit 1
fi
echo "All provenance-script self-test scenarios behaved as expected."
