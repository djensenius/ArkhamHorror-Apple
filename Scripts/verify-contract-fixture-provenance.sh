#!/bin/sh
# Verifies that every vendored contract fixture this client bundles is byte-identical to
# the exact same path at the exact backend commit `ContractPin.current` pins to.
#
# `ContractFixtureDigestTests` (an offline, purely local unit test) only proves internal
# self-consistency: that the bundled bytes match a SHA-256 recorded *in this same repository*.
# Nothing stops a co-edited fixture and its digest from drifting together, undetected, since
# both live in the same PR. This script closes that gap by treating the pinned backend git
# commit itself as the authority: it fetches that exact, immutable commit from the upstream
# backend repository into a separate scratch directory and byte-compares each governed
# fixture against what is actually vendored here, catching substitution (bytes differ),
# removal/rename (path no longer exists at that commit), and a stale/incorrect pin (the
# commit doesn't exist, or the checked-out schema revision disagrees).
#
# This script never builds or executes any backend code: it only fetches one immutable git
# commit and reads specific file paths out of it.
set -eu

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
contract_pin_file="$repo_root/Packages/ArkhamHorrorShared/Sources/ArkhamHorrorShared/Domain/Contract/ContractPin.swift"
local_fixture_dir="$repo_root/Packages/ArkhamHorrorShared/Tests/ArkhamHorrorSharedTests/Fixtures/Contract"
# A scratch directory under the repository's own (gitignored) `.build/`, never `/tmp`, so
# repeated local runs are easy to inspect/clean and nothing here depends on OS temp-dir
# behavior.
scratch_dir="$repo_root/.build/contract-fixture-provenance"
backend_repo_url="https://github.com/djensenius/ArkhamHorror.git"

if [ ! -f "$contract_pin_file" ]; then
  echo "error: could not find $contract_pin_file" >&2
  exit 1
fi

# Single source of truth: the exact commit SHA compiled into this client build. Extracted
# from the Swift source itself (never duplicated as a second hardcoded literal) so this
# script cannot silently drift from `ContractPin.current`.
backend_commit=$(grep -o 'backendCommit: "[0-9a-f]\{40\}"' "$contract_pin_file" | head -n1 | sed 's/.*"\([0-9a-f]*\)"/\1/')
if [ -z "$backend_commit" ]; then
  echo "error: could not extract a 40-character backendCommit SHA from $contract_pin_file" >&2
  exit 1
fi
echo "Verifying vendored contract fixtures against backend commit $backend_commit"

# local fixture basename : path at that commit in djensenius/ArkhamHorror
fixture_paths="
manifest.json:contracts/manifest.json
capabilities.json:contracts/fixtures/capabilities.json
catalog.json:contracts/fixtures/catalog.json
decks.json:contracts/fixtures/decks.json
game-lifecycle.json:contracts/fixtures/game-lifecycle.json
game-list.json:contracts/fixtures/game-list.json
"

rm -rf "$scratch_dir"
mkdir -p "$scratch_dir"
git init -q "$scratch_dir"

# Only the specific backend paths this script actually compares — never the whole backend
# tree — get materialized into the scratch working directory below.
backend_paths=""
for entry in $fixture_paths; do
  [ -z "$entry" ] && continue
  backend_paths="$backend_paths ${entry#*:}"
done

(
  cd "$scratch_dir"
  git remote add origin "$backend_repo_url"
  # A shallow, single-commit fetch of exactly the pinned SHA: never a branch/tag, and
  # never a full clone, so nothing here depends on (or executes) anything else in the
  # backend repository's history or build tooling.
  git fetch --depth 1 origin "$backend_commit"
  # Check out only the governed fixture paths (never `-- .`), so this step's own I/O and
  # working-tree footprint stay proportional to the handful of files actually compared.
  # $backend_paths is a space-separated list of literal, script-controlled path fragments
  # (no globs, no external input), so passing it unquoted here to split into separate
  # pathspec arguments is safe and intentional.
  # shellcheck disable=SC2086
  git checkout -q FETCH_HEAD -- $backend_paths
)

failures=0
for entry in $fixture_paths; do
  [ -z "$entry" ] && continue
  local_name="${entry%%:*}"
  backend_path="${entry#*:}"
  local_file="$local_fixture_dir/$local_name"
  backend_file="$scratch_dir/$backend_path"

  if [ ! -f "$local_file" ]; then
    echo "MISSING (local): $local_file is not vendored" >&2
    failures=$((failures + 1))
    continue
  fi
  if [ ! -f "$backend_file" ]; then
    echo "MISSING (backend): $backend_path does not exist at $backend_commit" >&2
    failures=$((failures + 1))
    continue
  fi
  if ! cmp -s "$local_file" "$backend_file"; then
    echo "DRIFT: $local_name differs from $backend_path at $backend_commit" >&2
    failures=$((failures + 1))
    continue
  fi
  echo "OK: $local_name matches $backend_path at $backend_commit"
done

if [ "$failures" -ne 0 ]; then
  echo "error: $failures governed contract fixture(s) failed provenance verification" >&2
  exit 1
fi

echo "All governed contract fixtures match backend commit $backend_commit exactly."
