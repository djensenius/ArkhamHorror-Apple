#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
script_under_test="$repo_root/Scripts/run-production-assignment-replay.sh"
harness_root="$repo_root/.build/production-assignment-replay-selftest.$$"
fake_curl="$harness_root/fake-curl"
fake_swift="$harness_root/fake-swift"
checkpoint="$harness_root/assignment.checkpoint.json"
token_file="$harness_root/token"
secret='selftest-token-never-in-curl-argv'

cleanup() {
  rm -rf "$harness_root"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$harness_root"
chmod 700 "$harness_root"
printf '%s\n' "$secret" >"$token_file"
chmod 600 "$token_file"

python3 - "$checkpoint" <<'PY'
import json
import pathlib
import sys

value = {
    "replayCheckpoint": {
        "type": "arkham-replay-checkpoint",
        "provenance": {
            "schemaVersion": 1,
            "contractSchemaRevision": "0.1.33",
            "sourceGameGitRevision": "c" * 40,
            "checkpoint": {
                "type": "question",
                "name": "enemy-attack-assignment-continuation",
                "questionVersion": 6,
                "playerId": "00000000-0000-0000-0000-000000000001",
                "promptTag": "QuestionWithSource",
                "promptSha256": "d" * 64,
            },
        },
        "envelopeSha256": "e" * 64,
    },
}
pathlib.Path(sys.argv[1]).write_bytes(
    json.dumps(value, separators=(",", ":"), sort_keys=True).encode()
)
PY
chmod 600 "$checkpoint"

cat >"$fake_curl" <<'SH'
#!/bin/bash
set -euo pipefail

printf '%s\n' '--- call ---' >>"$SELFTEST_CURL_LOG"
output=''
header=''
url=''
while [[ "$#" -gt 0 ]]; do
  printf '%s\n' "$1" >>"$SELFTEST_CURL_LOG"
  case "$1" in
    --output | --header | --form)
      option="$1"
      shift
      [[ "$#" -gt 0 ]]
      printf '%s\n' "$1" >>"$SELFTEST_CURL_LOG"
      case "$option" in
        --output) output="$1" ;;
        --header) header="$1" ;;
      esac
      ;;
    http://* | https://*) url="$1" ;;
  esac
  shift
done

[[ "$header" == @* ]]
header_file="${header#@}"
[[ -f "$header_file" && ! -L "$header_file" ]]
[[ "$(stat -f '%Lp' "$header_file")" == 600 ]]
[[ "$(cat "$header_file")" == "Authorization: Token $SELFTEST_SECRET" ]]
[[ -n "$output" && -n "$url" ]]

case "$url" in
  */games/import\?*)
    count=0
    if [[ -f "$SELFTEST_IMPORT_COUNT" ]]; then
      count="$(cat "$SELFTEST_IMPORT_COUNT")"
    fi
    count=$((count + 1))
    printf '%s\n' "$count" >"$SELFTEST_IMPORT_COUNT"
    printf '{"id":"00000000-0000-0000-0000-00000000010%s"}' "$count" >"$output"
    ;;
  */games/00000000-0000-0000-0000-000000000101)
    printf '{"playerId":"00000000-0000-0000-0000-000000000201"}' >"$output"
    ;;
  */games/00000000-0000-0000-0000-000000000102)
    printf '{"playerId":"00000000-0000-0000-0000-000000000202"}' >"$output"
    ;;
  *)
    printf 'unexpected fake curl URL: %s\n' "$url" >&2
    exit 1
    ;;
esac
SH
chmod 700 "$fake_curl"

cat >"$fake_swift" <<'SH'
#!/bin/bash
set -euo pipefail

printf '%s\n' "$ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_CASE" >>"$SELFTEST_SWIFT_LOG"
if [[ "${ARKHAM_REPLAY_SELFTEST_FAIL_CASE:-}" == "$ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_CASE" ]]; then
  exit 23
fi

python3 - <<'PY'
import hashlib
import json
import os
import pathlib

checkpoint_path = pathlib.Path(
    os.environ["ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_CHECKPOINT_ARTIFACT_PATH"]
)
checkpoint_bytes = checkpoint_path.read_bytes()
checkpoint = json.loads(checkpoint_bytes)["replayCheckpoint"]
provenance = checkpoint["provenance"]
identity = provenance["checkpoint"]
case_name = os.environ["ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_CASE"]
source_index = 0 if case_name == "damage-first-then-remaining-horror" else 1
selected = "damage" if source_index == 0 else "horror"
next_assignment = "horror" if source_index == 0 else "damage"
assignment_after = (
    {"assignedHealthDamage": 1, "assignedSanityDamage": 0}
    if source_index == 0
    else {"assignedHealthDamage": 0, "assignedSanityDamage": 1}
)
player_id = os.environ["ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_PLAYER_ID"]
question_version = identity["questionVersion"]
evidence = {
    "answer": {
        "contents": {
            "choice": source_index,
            "playerId": player_id,
            "questionVersion": question_version,
        },
        "tag": "Answer",
    },
    "assignmentAfter": assignment_after,
    "assignmentBefore": {
        "assignedHealthDamage": 0,
        "assignedSanityDamage": 0,
    },
    "assignmentDelta": assignment_after,
    "checkpoint": {
        "artifactSHA256": hashlib.sha256(checkpoint_bytes).hexdigest(),
        "caseName": case_name,
        "envelopeSHA256": checkpoint["envelopeSha256"],
        "name": identity["name"],
        "playerID": identity["playerId"],
        "promptCanonicalSHA256": identity["promptSha256"],
        "questionVersion": question_version,
    },
    "controller": {
        "focusAfterJump": "prompt-choice-0",
        "focusBeforePrimaryAction": f"prompt-choice-{source_index}",
        "jumpToActivePromptHandled": True,
        "movedToSelectedSourceIndex": source_index == 1,
        "primaryActionHandled": True,
    },
    "nextPrompt": {
        "assignment": next_assignment,
        "canonicalSHA256": "f" * 64,
        "promptTag": "QuestionWithSource",
        "sourceTag": "EnemyAttackSource",
        "version": question_version + 1,
    },
    "revisions": {
        "apple": os.environ[
            "ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_EXPECTED_APPLE_REVISION"
        ],
        "catalog": os.environ[
            "ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_EXPECTED_CATALOG_REVISION"
        ],
        "contract": os.environ[
            "ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_EXPECTED_CONTRACT_REVISION"
        ],
        "game": provenance["sourceGameGitRevision"],
        "serverBuild": {
            "attestation": "git-clean",
            "gitRevision": "5acc0237b216e3b70ebe30af1559ab0e627e4f56",
            "gitTree": "1" * 40,
            "sourceClean": True,
            "sourceSha256": "2" * 64,
        },
    },
    "schemaVersion": "2.0.0",
    "source": {
        "enemyID": os.environ[
            "ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_EXPECTED_STARTING_PROMPT_ENEMY_ID"
        ],
        "gameID": os.environ["ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_GAME_ID"],
        "investigatorID": os.environ[
            "ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_EXPECTED_STARTING_PROMPT_INVESTIGATOR_ID"
        ],
        "playerID": player_id,
        "promptCanonicalSHA256": identity["promptSha256"],
        "promptTag": "QuestionWithSource",
        "promptVersion": question_version,
        "selectedAssignment": selected,
        "sourceIndex": source_index,
        "sourceTag": "EnemyAttackSource",
    },
}
canonical_evidence = json.dumps(
    evidence, ensure_ascii=False, separators=(",", ":"), sort_keys=True
).encode()
artifact = {
    "evidence": evidence,
    "evidenceCanonicalSHA256": hashlib.sha256(canonical_evidence).hexdigest(),
}
destination = pathlib.Path(
    os.environ["ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_RESULT_PATH"]
)
destination.write_bytes(
    json.dumps(
        artifact, ensure_ascii=False, separators=(",", ":"), sort_keys=True
    ).encode()
)
destination.chmod(0o600)
PY
SH
chmod 700 "$fake_swift"

export SELFTEST_SECRET="$secret"
export SELFTEST_CURL_LOG="$harness_root/curl-argv.log"
export SELFTEST_SWIFT_LOG="$harness_root/swift-calls.log"
export SELFTEST_IMPORT_COUNT="$harness_root/import-count"
export ARKHAM_REPLAY_CURL_BIN="$fake_curl"
export ARKHAM_REPLAY_SWIFT_BIN="$fake_swift"
export ARKHAM_REPLAY_BASE_URL="http://127.0.0.1:3000"
export ARKHAM_REPLAY_INVESTIGATOR_ID="c01234"
export ARKHAM_REPLAY_ENEMY_ID="00000000-0000-0000-0000-000000000301"
export ARKHAM_REPLAY_EXPECTED_CONTRACT_REVISION="0.1.33"
export ARKHAM_REPLAY_EXPECTED_CATALOG_REVISION="1.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

reset_fake_state() {
  rm -f "$SELFTEST_CURL_LOG" "$SELFTEST_SWIFT_LOG" "$SELFTEST_IMPORT_COUNT"
}

fail_test() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

success_output="$harness_root/success-output"
reset_fake_state
"$script_under_test" "$checkpoint" "$success_output" "$token_file" >/dev/null
[[ -f "$success_output/damage-first.json" ]] ||
  fail_test "success did not create damage-first evidence"
[[ -f "$success_output/horror-first.json" ]] ||
  fail_test "success did not create horror-first evidence"
[[ "$(find "$success_output" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" == 2 ]] ||
  fail_test "success left stale/intermediate files"
[[ "$(stat -f '%Lp' "$success_output")" == 700 ]] ||
  fail_test "success output directory is not mode 0700"
if grep -F "$secret" "$SELFTEST_CURL_LOG" >/dev/null; then
  fail_test "token appeared in curl argv"
fi
printf 'PASS: fresh two-case success and credential cleanup\n'

first_failure_output="$harness_root/first-failure-output"
reset_fake_state
if ARKHAM_REPLAY_SELFTEST_FAIL_CASE="damage-first-then-remaining-horror" \
  "$script_under_test" "$checkpoint" "$first_failure_output" "$token_file" \
  >/dev/null 2>&1; then
  fail_test "first-case failure returned success"
fi
[[ ! -e "$first_failure_output" ]] ||
  fail_test "first-case failure preserved partial output"
[[ "$(wc -l <"$SELFTEST_SWIFT_LOG" | tr -d ' ')" == 1 ]] ||
  fail_test "second case ran after first-case failure"
printf 'PASS: first-case failure is fail-fast and removes partial output\n'

stale_output="$harness_root/stale-output"
mkdir -m 700 "$stale_output"
printf 'stale\n' >"$stale_output/damage-first.json"
reset_fake_state
if "$script_under_test" "$checkpoint" "$stale_output" "$token_file" \
  >/dev/null 2>&1; then
  fail_test "preexisting output directory returned success"
fi
[[ "$(cat "$stale_output/damage-first.json")" == stale ]] ||
  fail_test "preexisting stale output was overwritten"
[[ ! -e "$SELFTEST_SWIFT_LOG" ]] ||
  fail_test "Swift ran despite a preexisting output directory"
printf 'PASS: preexisting/stale output is rejected without overwrite\n'

printf '3 production assignment replay wrapper scenarios passed.\n'
