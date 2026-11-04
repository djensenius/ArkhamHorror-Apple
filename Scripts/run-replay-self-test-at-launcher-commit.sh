#!/bin/bash
# Runs this checkout's committed replay self-test against the audited
# production launcher, exactly as CI does.
#
# The launcher only runs from a clean checkout whose HEAD is the single commit
# that last changed it (its parent must be the launcher's pinned
# trusted_base_revision, and the replay package tree is pinned too). A checkout
# of any later commit therefore cannot run the self-test in place, and running
# it from the launcher commit would test the launcher commit's self-test, not
# this one.
#
# So this script builds a synthetic "graft" commit: the launcher commit's tree
# with only Scripts/test-run-production-assignment-replay.sh replaced by HEAD's
# committed version, parented on the launcher commit's parent. The launcher,
# its pins, and every other file stay byte-for-byte the audited launcher
# commit, so the launcher's identity checks still hold (HEAD^ is the trusted
# base, HEAD owns the launcher, package tree and launcher bytes are unchanged,
# origin is unchanged, and the detached worktree is clean). This runs the new
# self-test against the AUDITED launcher; it never vouches for a launcher edit.
set -euo pipefail

readonly git_bin="/usr/bin/git"
readonly launcher_path="Scripts/run-production-assignment-replay.sh"
readonly selftest_path="Scripts/test-run-production-assignment-replay.sh"
readonly package_path="Packages/ArkhamHorrorShared"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

repository_root="$("$git_bin" rev-parse --show-toplevel)"
readonly repository_root
cd "$repository_root"

head_revision="$("$git_bin" rev-parse --verify 'HEAD^{commit}')"
launcher_revision="$("$git_bin" log -1 --format=%H -- "$launcher_path")"
readonly head_revision launcher_revision
[[ "$launcher_revision" =~ ^[0-9a-f]{40}$ ]] ||
  fail "production launcher commit is unavailable"
launcher_parent="$("$git_bin" rev-parse --verify "$launcher_revision^")"
readonly launcher_parent

if ! "$git_bin" diff --quiet HEAD -- "$selftest_path"; then
  printf 'note: uncommitted changes to %s are not tested; the committed HEAD version is\n' \
    "$selftest_path"
fi

scratch_root="$(/usr/bin/mktemp -d /private/tmp/arkham-replay-selftest.XXXXXX)"
readonly scratch_root
/bin/chmod 700 "$scratch_root"
readonly replay_worktree="$scratch_root/checkout"
readonly graft_index="$scratch_root/index"
worktree_added=0

cleanup() {
  local exit_status=$?
  trap - EXIT HUP INT TERM
  set +e
  if [[ "$worktree_added" == 1 ]]; then
    "$git_bin" worktree remove --force "$replay_worktree" >/dev/null 2>&1 ||
      printf 'warning: could not remove %s\n' "$replay_worktree" >&2
  fi
  "$git_bin" worktree prune >/dev/null 2>&1
  /bin/rm -f -- "$graft_index"
  /bin/rmdir -- "$scratch_root" 2>/dev/null ||
    printf 'warning: could not remove %s\n' "$scratch_root" >&2
  exit "$exit_status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

head_entry="$("$git_bin" ls-tree "$head_revision" -- "$selftest_path")"
launcher_entry="$("$git_bin" ls-tree "$launcher_revision" -- "$selftest_path")"
read -r head_mode _ head_blob _ <<<"$head_entry"
read -r launcher_mode _ launcher_blob _ <<<"$launcher_entry"
[[ "$head_blob" =~ ^[0-9a-f]{40}$ && "$launcher_blob" =~ ^[0-9a-f]{40}$ ]] ||
  fail "replay self-test is missing from HEAD or the launcher commit"

if [[ "$head_blob" == "$launcher_blob" && "$head_mode" == "$launcher_mode" ]]; then
  run_revision="$launcher_revision"
else
  GIT_INDEX_FILE="$graft_index" "$git_bin" read-tree "$launcher_revision"
  GIT_INDEX_FILE="$graft_index" "$git_bin" update-index \
    --cacheinfo "$head_mode,$head_blob,$selftest_path"
  graft_tree="$(GIT_INDEX_FILE="$graft_index" "$git_bin" write-tree)"
  run_revision="$(
    GIT_AUTHOR_NAME="ArkhamHorror replay self-test" \
      GIT_AUTHOR_EMAIL="replay-self-test@invalid" \
      GIT_AUTHOR_DATE="2000-01-01T00:00:00Z" \
      GIT_COMMITTER_NAME="ArkhamHorror replay self-test" \
      GIT_COMMITTER_EMAIL="replay-self-test@invalid" \
      GIT_COMMITTER_DATE="2000-01-01T00:00:00Z" \
      "$git_bin" commit-tree "$graft_tree" -p "$launcher_parent" \
      -m "Replay self-test graft: launcher $launcher_revision, self-test from $head_revision"
  )"
fi
readonly run_revision

# The graft may differ from the launcher commit in the self-test only.
changed_paths="$("$git_bin" diff-tree -r --name-only "$launcher_revision" "$run_revision")"
[[ -z "$changed_paths" || "$changed_paths" == "$selftest_path" ]] ||
  fail "graft changed more than the self-test: $changed_paths"
[[ "$("$git_bin" rev-parse "$run_revision:$launcher_path")" == \
  "$("$git_bin" rev-parse "$launcher_revision:$launcher_path")" &&
  "$("$git_bin" rev-parse "$run_revision:$package_path")" == \
  "$("$git_bin" rev-parse "$launcher_revision:$package_path")" ]] ||
  fail "graft does not keep the audited launcher and replay package"

printf 'replay self-test revision: %s\n' "$run_revision"
printf '  parent:           %s\n' "$("$git_bin" rev-parse "$run_revision^")"
printf '  launcher commit:  %s\n' "$launcher_revision"
printf '  self-test from:   %s (HEAD)\n' "$head_revision"

"$git_bin" worktree add --detach "$replay_worktree" "$run_revision"
worktree_added=1
env -u DEVELOPER_DIR "$replay_worktree/$selftest_path"
