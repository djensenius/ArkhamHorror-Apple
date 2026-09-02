#!/bin/sh
# Verifies that every vendored raw locale digest fixture this client bundles is
# byte-identical to the exact same path at the exact upstream web-client commit
# `LocaleDigestProvenance.upstreamCommit` pins to.
#
# `LocaleDigestFixtureProvenanceTests` (an offline, purely local unit test) only proves
# internal self-consistency: that the bundled bytes match a SHA-256 recorded *in this same
# repository*, and that the local `Fixtures/LocaleDigests/raw` directory's own file listing
# matches that same registry. Nothing stops a co-edited fixture, its digest, *and* this
# script's own governed path map from drifting together, undetected, since all three could
# be edited in the same PR. This script closes that gap by treating the pinned upstream git
# commit itself as the authority: it fetches that exact, immutable commit from the upstream
# web-client repository into a separate scratch directory and byte-compares each governed
# fixture against what is actually vendored here, catching substitution (bytes differ),
# removal/rename (path no longer exists at that commit, or an unregistered file appears
# locally), a stale/incorrect pin (the commit doesn't exist), a local symlink or non-regular
# file standing in for real vendored bytes, an upstream path that is not a regular blob (for
# example a symlink or submodule gitlink) at the pinned commit, and a Git repository/commit
# identity mismatch (the scratch remote no longer points at the expected upstream repository
# URL, or the fetched `FETCH_HEAD` does not resolve to exactly the pinned 40-character commit
# SHA).
#
# This script never builds or executes any upstream code: it only fetches one immutable git
# commit and reads specific file paths out of it. Mirrors
# `Scripts/verify-contract-fixture-provenance.sh`'s own pattern for the backend contract
# fixtures.
#
# Every path below is a literal, this-script-controlled fragment (never external input), but
# each is still explicitly validated to reject `..` traversal and absolute paths as
# defense-in-depth against a future edit accidentally introducing one.
#
# The `LOCALE_PROVENANCE_*` environment variables below all default to the real, production
# configuration and exist solely so `Scripts/test-verify-locale-digest-provenance.sh` can
# point this script at disposable, fully offline scratch git repositories to exercise every
# failure mode (symlink-to-identical-bytes, wrong mode, extra/missing files, altered bytes,
# an unregistered path) without any network access and without mutating the real vendored
# fixtures or `LocaleDigestFixtureProvenance.swift`.
set -eu

repo_root_default="$(cd "$(dirname "$0")/.." && pwd)"
repo_root="${LOCALE_PROVENANCE_REPO_ROOT:-$repo_root_default}"
provenance_file="${LOCALE_PROVENANCE_FILE:-$repo_root_default/Packages/ArkhamHorrorShared/Sources/ArkhamHorrorShared/Domain/Asset/LocaleDigestFixtureProvenance.swift}"
# A scratch directory under the repository's own (gitignored) `.build/`, never `/tmp`, so
# repeated local runs are easy to inspect/clean and nothing here depends on OS temp-dir
# behavior.
scratch_dir="${LOCALE_PROVENANCE_SCRATCH_DIR:-$repo_root_default/.build/locale-digest-provenance}"
upstream_repo_url="${LOCALE_PROVENANCE_REPO_URL:-https://github.com/djensenius/ArkhamHorror.git}"
# A dedicated directory containing nothing but governed raw locale digest fixtures (see
# `LocaleDigestFixtureProvenanceTests` for the corresponding offline enumeration).
local_fixture_dir="${LOCALE_PROVENANCE_LOCAL_FIXTURE_DIR:-$repo_root_default/Packages/ArkhamHorrorShared/Tests/ArkhamHorrorSharedTests/Fixtures/LocaleDigests/raw}"

if [ ! -f "$provenance_file" ]; then
  echo "error: could not find $provenance_file" >&2
  exit 1
fi

# Single source of truth: the exact commit SHA compiled into this client build. Extracted
# from the Swift source itself (never duplicated as a second hardcoded literal) so this
# script cannot silently drift from `LocaleDigestProvenance.upstreamCommit`.
# `LOCALE_PROVENANCE_COMMIT` overrides this only for the offline self-test harness, which
# cannot reasonably fabricate a git commit whose SHA matches the real pinned upstream commit.
upstream_commit="${LOCALE_PROVENANCE_COMMIT:-}"
if [ -z "$upstream_commit" ]; then
  upstream_commit=$(grep -o 'upstreamCommit = "[0-9a-f]\{40\}"' "$provenance_file" | head -n1 | sed 's/.*"\([0-9a-f]*\)"/\1/')
fi
if [ -z "$upstream_commit" ]; then
  echo "error: could not extract a 40-character upstreamCommit SHA from $provenance_file" >&2
  exit 1
fi

echo "Verifying vendored raw locale digest fixtures against upstream commit $upstream_commit"

# local fixture basename : path at that commit in djensenius/ArkhamHorror
fixture_paths="
it.json:frontend/src/digests/ita.json
fr.json:frontend/src/digests/fr.json
es.json:frontend/src/digests/es.json
ko.json:frontend/src/digests/ko.json
zh.json:frontend/src/digests/zh.json
"

# Rejects an absolute path or any `..` path-traversal component in a (script-controlled,
# never externally supplied) upstream path fragment before it is ever used to build a
# filesystem path or passed to `git checkout`/`git ls-tree`.
assert_normalized_relative_path() {
  candidate="$1"
  case "$candidate" in
    /*)
      echo "error: upstream path '$candidate' must be relative, not absolute" >&2
      exit 1
      ;;
  esac
  case "/$candidate/" in
    */../* | */./*)
      echo "error: upstream path '$candidate' must not contain '.' or '..' components" >&2
      exit 1
      ;;
  esac
}

failures=0

# --- Local directory-set agreement -----------------------------------------------------
#
# Enumerates the *actual* files vendored under `local_fixture_dir` and requires that set to
# exactly match the basenames this script itself governs above -- not only what a
# separately co-editable Swift unit test happens to enumerate.
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

# Only the specific upstream paths this script actually compares — never the whole upstream
# tree — get materialized into the scratch working directory below.
upstream_paths=""
for entry in $fixture_paths; do
  [ -z "$entry" ] && continue
  upstream_path="${entry#*:}"
  assert_normalized_relative_path "$upstream_path"
  upstream_paths="$upstream_paths $upstream_path"
done

(
  cd "$scratch_dir"
  git remote add origin "$upstream_repo_url"
  # A shallow, single-commit fetch of exactly the pinned SHA: never a branch/tag, and
  # never a full clone.
  git fetch --depth 1 origin "$upstream_commit"
  actual_remote_url=$(git remote get-url origin)
  if [ "$actual_remote_url" != "$upstream_repo_url" ]; then
    echo "error: scratch repository remote '$actual_remote_url' does not match the" \
      "expected upstream repository URL '$upstream_repo_url'" >&2
    exit 1
  fi
  actual_fetch_head=$(git rev-parse FETCH_HEAD)
  if [ "$actual_fetch_head" != "$upstream_commit" ]; then
    echo "error: fetched FETCH_HEAD '$actual_fetch_head' does not match the pinned" \
      "upstream commit '$upstream_commit'" >&2
    exit 1
  fi
  # shellcheck disable=SC2086
  git checkout -q FETCH_HEAD -- $upstream_paths
)

# Verifies, via `git ls-tree` against the pinned commit itself, that an upstream path is a
# regular file blob at exactly mode 100644 -- not a symlink (120000), an executable
# (100755), a submodule gitlink (160000), or a tree/directory.
assert_upstream_path_is_regular_blob() {
  upstream_path="$1"
  ls_tree_line=$(git -C "$scratch_dir" ls-tree FETCH_HEAD -- "$upstream_path")
  if [ -z "$ls_tree_line" ]; then
    echo "MISSING (upstream): $upstream_path does not exist at $upstream_commit" >&2
    return 1
  fi
  mode=$(echo "$ls_tree_line" | awk '{print $1}')
  type=$(echo "$ls_tree_line" | awk '{print $2}')
  if [ "$type" != "blob" ] || [ "$mode" != "100644" ]; then
    echo "DRIFT: $upstream_path at $upstream_commit is not a regular (100644) blob" \
      "(found type=$type mode=$mode)" >&2
    return 1
  fi
  return 0
}

# Verifies, via the *local repository's own index* (not merely a working-tree stat), that a
# vendored fixture is tracked as a regular file at exactly mode 100644.
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
  upstream_path="${entry#*:}"
  local_file="$local_fixture_dir/$local_name"
  upstream_file="$scratch_dir/$upstream_path"

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
  if ! assert_upstream_path_is_regular_blob "$upstream_path"; then
    failures=$((failures + 1))
    continue
  fi
  if [ ! -f "$upstream_file" ]; then
    echo "MISSING (upstream): $upstream_path does not exist at $upstream_commit" >&2
    failures=$((failures + 1))
    continue
  fi
  if ! cmp -s "$local_file" "$upstream_file"; then
    echo "DRIFT: $local_name differs from $upstream_path at $upstream_commit" >&2
    failures=$((failures + 1))
    continue
  fi
  echo "OK: $local_name matches $upstream_path at $upstream_commit (regular 100644 blob)"
done

if [ "$failures" -ne 0 ]; then
  echo "error: $failures governed locale digest fixture provenance check(s) failed" >&2
  exit 1
fi

echo "All governed raw locale digest fixtures match upstream commit $upstream_commit exactly."
