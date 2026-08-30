#!/bin/sh
# Verifies that every vendored contract fixture this client bundles is byte-identical to
# the exact same path at the exact backend commit `ContractPin.current` pins to.
#
# `ContractFixtureDigestTests` (an offline, purely local unit test) only proves internal
# self-consistency: that the bundled bytes match a SHA-256 recorded *in this same repository*,
# and that the local `Fixtures/Contract` directory's own file listing matches that same
# registry. Nothing stops a co-edited fixture, its digest, *and* this script's own governed
# path map from drifting together, undetected, since all three could be edited in the same
# PR. This script closes that gap by treating the pinned backend git commit itself as the
# authority: it fetches that exact, immutable commit from the upstream backend repository
# into a separate scratch directory and byte-compares each governed fixture against what is
# actually vendored here, catching substitution (bytes differ), removal/rename (path no
# longer exists at that commit, or an unregistered file appears locally), a stale/incorrect
# pin (the commit doesn't exist, or the checked-out schema revision disagrees), a local
# symlink or non-regular file standing in for real vendored bytes, a backend path that is
# not a regular blob (for example a symlink or submodule gitlink) at the pinned commit, and
# a Git repository/commit identity mismatch (the scratch remote no longer points at the
# expected backend repository URL, or the fetched `FETCH_HEAD` does not resolve to exactly
# the pinned 40-character commit SHA).
#
# This script never builds or executes any backend code: it only fetches one immutable git
# commit and reads specific file paths out of it.
#
# Every path below is a literal, this-script-controlled fragment (never external input), but
# each is still explicitly validated to reject `..` traversal and absolute paths as
# defense-in-depth against a future edit accidentally introducing one.
#
# The `PROVENANCE_*` environment variables below all default to the real, production
# configuration and exist solely so `Scripts/test-verify-contract-fixture-provenance.sh` can
# point this script at disposable, fully offline scratch git repositories to exercise every
# failure mode (symlink-to-identical-bytes, wrong mode, extra/missing files, altered bytes,
# an unregistered path) without any network access and without mutating the real vendored
# fixtures or `ContractPin.swift`.
set -eu

repo_root_default="$(cd "$(dirname "$0")/.." && pwd)"
repo_root="${PROVENANCE_REPO_ROOT:-$repo_root_default}"
contract_pin_file="${PROVENANCE_CONTRACT_PIN_FILE:-$repo_root_default/Packages/ArkhamHorrorShared/Sources/ArkhamHorrorShared/Domain/Contract/ContractPin.swift}"
# A scratch directory under the repository's own (gitignored) `.build/`, never `/tmp`, so
# repeated local runs are easy to inspect/clean and nothing here depends on OS temp-dir
# behavior.
scratch_dir="${PROVENANCE_SCRATCH_DIR:-$repo_root_default/.build/contract-fixture-provenance}"
backend_repo_url="${PROVENANCE_BACKEND_REPO_URL:-https://github.com/djensenius/ArkhamHorror.git}"
# `local_fixture_dir` is intentionally a *dedicated* subdirectory containing nothing but
# governed contract artifacts (see `ContractFixtureDigestTests` for the corresponding
# offline enumeration). Unrelated synthetic fixtures (for example authentication fixtures)
# live one level up, in `Fixtures/`, deliberately outside this directory, so they are never
# mistaken for governed contract artifacts by either this script or that test.
local_fixture_dir="${PROVENANCE_LOCAL_FIXTURE_DIR:-$repo_root_default/Packages/ArkhamHorrorShared/Tests/ArkhamHorrorSharedTests/Fixtures/Contract}"

if [ ! -f "$contract_pin_file" ]; then
  echo "error: could not find $contract_pin_file" >&2
  exit 1
fi

# Single source of truth: the exact commit SHA compiled into this client build. Extracted
# from the Swift source itself (never duplicated as a second hardcoded literal) so this
# script cannot silently drift from `ContractPin.current`. `PROVENANCE_BACKEND_COMMIT`
# overrides this only for the offline self-test harness, which cannot reasonably fabricate
# a git commit whose SHA matches the real pinned upstream commit.
backend_commit="${PROVENANCE_BACKEND_COMMIT:-}"
if [ -z "$backend_commit" ]; then
  backend_commit=$(grep -o 'backendCommit: "[0-9a-f]\{40\}"' "$contract_pin_file" | head -n1 | sed 's/.*"\([0-9a-f]*\)"/\1/')
fi
if [ -z "$backend_commit" ]; then
  echo "error: could not extract a 40-character backendCommit SHA from $contract_pin_file" >&2
  exit 1
fi

# The schema revision compiled into this client, likewise extracted from the Swift source
# rather than duplicated as a second literal, so a pin bump can't update the commit without
# updating the revision it claims (or vice versa) without this script noticing.
pin_schema_line=$(grep 'supportedSchemaRevision: \.literal' "$contract_pin_file" | head -n1)
pin_major=$(echo "$pin_schema_line" | sed -n 's/.*major: \([0-9]*\).*/\1/p')
pin_minor=$(echo "$pin_schema_line" | sed -n 's/.*minor: \([0-9]*\).*/\1/p')
pin_patch=$(echo "$pin_schema_line" | sed -n 's/.*patch: \([0-9]*\).*/\1/p')
if [ -z "$pin_major" ] || [ -z "$pin_minor" ] || [ -z "$pin_patch" ]; then
  echo "error: could not extract supportedSchemaRevision major/minor/patch from $contract_pin_file" >&2
  exit 1
fi
pin_schema_revision="$pin_major.$pin_minor.$pin_patch"

echo "Verifying vendored contract fixtures against backend commit $backend_commit"

# local fixture basename : path at that commit in djensenius/ArkhamHorror
fixture_paths="
manifest.json:contracts/manifest.json
capabilities.json:contracts/fixtures/capabilities.json
catalog.json:contracts/fixtures/catalog.json
decks.json:contracts/fixtures/decks.json
game-lifecycle.json:contracts/fixtures/game-lifecycle.json
game-list.json:contracts/fixtures/game-list.json
get-game.json:contracts/fixtures/get-game.json
game-update.json:contracts/fixtures/game-update.json
mode-turn-zero.json:contracts/fixtures/mode-turn-zero.json
mode-campaign-only.json:contracts/fixtures/mode-campaign-only.json
mode-campaign-scenario.json:contracts/fixtures/mode-campaign-scenario.json
location-enemy-view.json:contracts/fixtures/location-enemy-view.json
movement.json:contracts/fixtures/movement.json
act-no-advance-cost.json:contracts/fixtures/act-no-advance-cost.json
investigator-unhealed-horror-negative.json:contracts/fixtures/investigator-unhealed-horror-negative.json
uuid-entity-map.json:contracts/fixtures/uuid-entity-map.json
card-code-entity-map.json:contracts/fixtures/card-code-entity-map.json
question-choose-one.json:contracts/fixtures/question-choose-one.json
question-player-window-choose-one.json:contracts/fixtures/question-player-window-choose-one.json
question-window-choose-one.json:contracts/fixtures/question-window-choose-one.json
answer-question.json:contracts/fixtures/answer-question.json
question-read.json:contracts/fixtures/question-read.json
question-read-with-cards.json:contracts/fixtures/question-read-with-cards.json
question-choose-one-location.json:contracts/fixtures/question-choose-one-location.json
question-choose-one-location-multiple.json:contracts/fixtures/question-choose-one-location-multiple.json
"

# Rejects an absolute path or any `..` path-traversal component in a (script-controlled,
# never externally supplied) backend path fragment before it is ever used to build a
# filesystem path or passed to `git checkout`/`git ls-tree`.
assert_normalized_relative_path() {
  candidate="$1"
  case "$candidate" in
    /*)
      echo "error: backend path '$candidate' must be relative, not absolute" >&2
      exit 1
      ;;
  esac
  case "/$candidate/" in
    */../* | */./*)
      echo "error: backend path '$candidate' must not contain '.' or '..' components" >&2
      exit 1
      ;;
  esac
}

failures=0

# --- Local directory-set agreement -----------------------------------------------------
#
# Enumerates the *actual* files vendored under `local_fixture_dir` and requires that set to
# exactly match the basenames this script itself governs above -- not only what a
# separately co-editable Swift unit test happens to enumerate. An addition, removal, or
# rename inside this directory that this script's own map was not updated to match fails
# here, rather than silently going unverified.
expected_local_names=$(
  for entry in $fixture_paths; do
    [ -z "$entry" ] && continue
    echo "${entry%%:*}"
  done | sort
)
if [ -d "$local_fixture_dir" ]; then
  actual_local_names=$(
    find "$local_fixture_dir" -mindepth 1 -maxdepth 1 -name '*.json' -print \
      | xargs -n1 basename \
      | sort
  )
else
  actual_local_names=""
fi
if [ "$expected_local_names" != "$actual_local_names" ]; then
  echo "DRIFT: $local_fixture_dir's actual file listing does not exactly match this script's governed path map" >&2
  echo "  expected: $(echo "$expected_local_names" | tr '\n' ' ')" >&2
  echo "  actual:   $(echo "$actual_local_names" | tr '\n' ' ')" >&2
  failures=$((failures + 1))
fi

rm -rf "$scratch_dir"
mkdir -p "$scratch_dir"
git init -q "$scratch_dir"

# Only the specific backend paths this script actually compares — never the whole backend
# tree — get materialized into the scratch working directory below.
backend_paths=""
for entry in $fixture_paths; do
  [ -z "$entry" ] && continue
  backend_path="${entry#*:}"
  assert_normalized_relative_path "$backend_path"
  backend_paths="$backend_paths $backend_path"
done

(
  cd "$scratch_dir"
  git remote add origin "$backend_repo_url"
  # A shallow, single-commit fetch of exactly the pinned SHA: never a branch/tag, and
  # never a full clone, so nothing here depends on (or executes) anything else in the
  # backend repository's history or build tooling.
  git fetch --depth 1 origin "$backend_commit"
  # Confirms this scratch repository's own remote is still configured to the exact
  # expected backend repository URL (defense against a future edit silently pointing
  # this script's actual runtime configuration somewhere else) and that what was just
  # fetched as `FETCH_HEAD` resolves to precisely the pinned 40-character commit SHA --
  # never a same-prefix collision, a mistakenly-abbreviated SHA, or a tag/branch that
  # happens to currently point at a different commit. This is the "Git repo identity"
  # half of provenance: byte/mode/manifest checks below are meaningless if the object
  # they're compared against didn't actually come from the exact expected repository at
  # the exact expected commit.
  actual_remote_url=$(git remote get-url origin)
  if [ "$actual_remote_url" != "$backend_repo_url" ]; then
    echo "error: scratch repository remote '$actual_remote_url' does not match the" \
      "expected backend repository URL '$backend_repo_url'" >&2
    exit 1
  fi
  actual_fetch_head=$(git rev-parse FETCH_HEAD)
  if [ "$actual_fetch_head" != "$backend_commit" ]; then
    echo "error: fetched FETCH_HEAD '$actual_fetch_head' does not match the pinned" \
      "backend commit '$backend_commit'" >&2
    exit 1
  fi
  # Check out only the governed fixture paths (never `-- .`), so this step's own I/O and
  # working-tree footprint stay proportional to the handful of files actually compared.
  # $backend_paths is a space-separated list of literal, script-controlled path fragments
  # (no globs, no external input, and each already validated above), so passing it
  # unquoted here to split into separate pathspec arguments is safe and intentional.
  # shellcheck disable=SC2086
  git checkout -q FETCH_HEAD -- $backend_paths
)

# Confirm the compiled-in schema revision actually matches the schemaRevision recorded in
# the pinned backend commit's own manifest, not just whatever the offline unit tests happen
# to assert against the locally vendored copy. This is what makes a stale/incorrect pin
# (backend commit exists, but its manifest disagrees with `ContractPin.current`) fail here
# rather than only in a separate, purely local test.
backend_manifest="$scratch_dir/contracts/manifest.json"
if [ ! -f "$backend_manifest" ]; then
  echo "MISSING (backend): contracts/manifest.json does not exist at $backend_commit" >&2
  failures=$((failures + 1))
else
  backend_schema_revision=$(grep -o '"schemaRevision" *: *"[^"]*"' "$backend_manifest" | head -n1 | sed 's/.*"\([^"]*\)"$/\1/')
  if [ -z "$backend_schema_revision" ]; then
    echo "error: could not extract schemaRevision from $backend_manifest" >&2
    failures=$((failures + 1))
  elif [ "$backend_schema_revision" != "$pin_schema_revision" ]; then
    echo "DRIFT: ContractPin.supportedSchemaRevision ($pin_schema_revision) does not match" \
      "backend manifest schemaRevision ($backend_schema_revision) at $backend_commit" >&2
    failures=$((failures + 1))
  else
    echo "OK: ContractPin.supportedSchemaRevision matches backend manifest schemaRevision ($pin_schema_revision)"
  fi
fi

# Verifies, via `git ls-tree` against the pinned commit itself, that a backend path is a
# regular file blob at exactly mode 100644 -- not a symlink (120000), an executable
# (100755), a submodule gitlink (160000), or a tree/directory. Checking only the checked-out
# working-tree bytes (as a plain `cmp`) cannot distinguish "a regular file with these bytes"
# from "a symlink that happens to resolve to a file with these bytes" once the working tree
# has already dereferenced it, so this inspects the tree object recorded at the commit
# directly instead.
assert_backend_path_is_regular_blob() {
  backend_path="$1"
  ls_tree_line=$(git -C "$scratch_dir" ls-tree FETCH_HEAD -- "$backend_path")
  if [ -z "$ls_tree_line" ]; then
    echo "MISSING (backend): $backend_path does not exist at $backend_commit" >&2
    return 1
  fi
  mode=$(echo "$ls_tree_line" | awk '{print $1}')
  type=$(echo "$ls_tree_line" | awk '{print $2}')
  if [ "$type" != "blob" ] || [ "$mode" != "100644" ]; then
    echo "DRIFT: $backend_path at $backend_commit is not a regular (100644) blob" \
      "(found type=$type mode=$mode)" >&2
    return 1
  fi
  return 0
}

# Verifies, via the *local repository's own index* (not merely a working-tree stat), that a
# vendored fixture is tracked as a regular file at exactly mode 100644. A file that is only
# present on disk (untracked, or a symlink the working tree happens to resolve to identical
# bytes) is exactly the kind of substitution `cmp` alone cannot catch, since `cmp` follows
# symlinks and has no concept of what git itself recorded for that path.
assert_local_path_is_regular_index_entry() {
  local_file="$1"
  local_relative_path="${local_file#"$repo_root"/}"
  ls_files_line=$(git -C "$repo_root" ls-files -s -- "$local_relative_path")
  if [ -z "$ls_files_line" ]; then
    echo "error: $local_relative_path is not tracked in $repo_root's git index" >&2
    return 1
  fi
  mode=$(echo "$ls_files_line" | awk '{print $1}')
  if [ "$mode" != "100644" ]; then
    echo "DRIFT: $local_relative_path is tracked at mode $mode, not the expected regular 100644" >&2
    return 1
  fi
  return 0
}

for entry in $fixture_paths; do
  [ -z "$entry" ] && continue
  local_name="${entry%%:*}"
  backend_path="${entry#*:}"
  local_file="$local_fixture_dir/$local_name"
  backend_file="$scratch_dir/$backend_path"

  # `-L` is checked *before* `-f`, and independently of it: a symlink whose target happens
  # to be a regular file (even one with byte-identical contents) must fail here rather than
  # silently being followed by `-f`/`cmp` below, since a symlink is not the vendored bytes
  # this script exists to verify -- it is a pointer to bytes that could live anywhere,
  # including outside this repository entirely or outside version control's own tracking
  # of what byte sequence "this fixture" actually is.
  if [ -L "$local_file" ]; then
    echo "DRIFT: $local_file is a symlink, not a regular vendored fixture file" >&2
    failures=$((failures + 1))
    continue
  fi
  if [ ! -f "$local_file" ]; then
    echo "MISSING (local): $local_file is not vendored" >&2
    failures=$((failures + 1))
    continue
  fi
  if ! assert_local_path_is_regular_index_entry "$local_file"; then
    failures=$((failures + 1))
    continue
  fi
  if ! assert_backend_path_is_regular_blob "$backend_path"; then
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
  # Every fixture other than the manifest itself must actually be *listed* by the pinned
  # backend's own manifest.json (never only by this script's local map): a fixture that is
  # byte-identical to a path at the pinned commit, but which that commit's own manifest does
  # not (or no longer) claims as a governed fixture, is not actually an authoritative
  # contract artifact -- it could be any incidental file that happens to still exist at that
  # path.
  if [ "$local_name" != "manifest.json" ] && [ -f "$backend_manifest" ]; then
    if ! grep -q "\"path\" *: *\"$backend_path\"" "$backend_manifest"; then
      echo "DRIFT: $backend_path is vendored and byte-identical, but the pinned backend's" \
        "own manifest.json does not list it as a fixture" >&2
      failures=$((failures + 1))
      continue
    fi
  fi
  echo "OK: $local_name matches $backend_path at $backend_commit (regular 100644 blob, manifest-listed)"
done

if [ "$failures" -ne 0 ]; then
  echo "error: $failures governed contract fixture provenance check(s) failed" >&2
  exit 1
fi

echo "All governed contract fixtures match backend commit $backend_commit exactly."
