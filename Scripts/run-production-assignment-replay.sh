#!/bin/bash
set -euo pipefail
set +x
umask 077

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
curl_bin="${ARKHAM_REPLAY_CURL_BIN:-curl}"
python_bin="${ARKHAM_REPLAY_PYTHON_BIN:-python3}"
swift_bin="${ARKHAM_REPLAY_SWIFT_BIN:-swift}"
git_bin="${ARKHAM_REPLAY_GIT_BIN:-/usr/bin/git}"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage: Scripts/run-production-assignment-replay.sh CHECKPOINT_JSON OUTPUT_DIRECTORY TOKEN_FILE

Required environment:
  ARKHAM_REPLAY_BASE_URL
  ARKHAM_REPLAY_INVESTIGATOR_ID
  ARKHAM_REPLAY_ENEMY_ID
  ARKHAM_REPLAY_EXPECTED_CONTRACT_REVISION
  ARKHAM_REPLAY_EXPECTED_CATALOG_REVISION

Optional environment:
  ARKHAM_REPLAY_SERVER_PROFILE_ID  (default: 00000000-0000-0000-0000-000000000777)
  ARKHAM_REPLAY_DEADLINE_SECONDS   (default: 60)
EOF
}

require_environment() {
  local name="$1"
  [[ -n "${!name:-}" ]] || fail "$name is required"
}

mode_of() {
  stat -f '%Lp' "$1"
}

owner_of() {
  stat -f '%u' "$1"
}

identity_of() {
  stat -f '%d:%i' "$1"
}

require_owned_regular_file() {
  local path="$1"
  local label="$2"
  [[ -f "$path" && ! -L "$path" ]] ||
    fail "$label must be a regular non-symlink file"
  [[ "$(owner_of "$path")" == "$(id -u)" ]] ||
    fail "$label must be owned by the current user"
}

[[ "$#" == 3 ]] || {
  usage
  exit 2
}

checkpoint_path="$1"
output_directory="$2"
token_file="$3"
case "$checkpoint_path" in
  /*) ;;
  *) fail "CHECKPOINT_JSON must be an absolute path" ;;
esac
case "$output_directory" in
  / | "") fail "OUTPUT_DIRECTORY must be a non-root absolute path" ;;
  /*) ;;
  *) fail "OUTPUT_DIRECTORY must be an absolute path" ;;
esac
case "$token_file" in
  /*) ;;
  *) fail "TOKEN_FILE must be an absolute path" ;;
esac

require_environment ARKHAM_REPLAY_BASE_URL
require_environment ARKHAM_REPLAY_INVESTIGATOR_ID
require_environment ARKHAM_REPLAY_ENEMY_ID
require_environment ARKHAM_REPLAY_EXPECTED_CONTRACT_REVISION
require_environment ARKHAM_REPLAY_EXPECTED_CATALOG_REVISION

server_base="${ARKHAM_REPLAY_BASE_URL%/}"
case "$server_base" in
  http://* | https://*) ;;
  *) fail "ARKHAM_REPLAY_BASE_URL must be an HTTP(S) URL" ;;
esac
[[ "$server_base" != *[$'\r\n\t ']* ]] ||
  fail "ARKHAM_REPLAY_BASE_URL contains whitespace"

checkpoint_path="$(
  cd "$(dirname "$checkpoint_path")"
  printf '%s/%s\n' "$(pwd -P)" "$(basename "$checkpoint_path")"
)"
token_file="$(
  cd "$(dirname "$token_file")"
  printf '%s/%s\n' "$(pwd -P)" "$(basename "$token_file")"
)"
require_owned_regular_file "$checkpoint_path" "CHECKPOINT_JSON"
require_owned_regular_file "$token_file" "TOKEN_FILE"
checkpoint_mode="$(mode_of "$checkpoint_path")"
(( (8#$checkpoint_mode & 0022) == 0 )) ||
  fail "CHECKPOINT_JSON must not be group- or world-writable"
[[ "$(mode_of "$token_file")" == "600" ]] ||
  fail "TOKEN_FILE must have mode 0600"

[[ ! -e "$output_directory" && ! -L "$output_directory" ]] ||
  fail "OUTPUT_DIRECTORY must not already exist"
output_parent="$(dirname "$output_directory")"
[[ -d "$output_parent" && ! -L "$output_parent" ]] ||
  fail "OUTPUT_DIRECTORY's parent must be a non-symlink directory"
output_parent="$(
  cd "$output_parent"
  pwd -P
)"
output_directory="$output_parent/$(basename "$output_directory")"
created_output=0
run_succeeded=0
output_identity=''

auth_header="$output_directory/.authorization-header"
damage_import="$output_directory/.damage-first.import.json"
horror_import="$output_directory/.horror-first.import.json"
damage_game="$output_directory/.damage-first.game.json"
horror_game="$output_directory/.horror-first.game.json"
damage_evidence="$output_directory/damage-first.json"
horror_evidence="$output_directory/horror-first.json"

cleanup_runtime_files() {
  rm -f "$auth_header" "$damage_import" "$horror_import" \
    "$damage_game" "$horror_game"
}

cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  set +e
  unset replay_token ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_AUTH_TOKEN
  cleanup_runtime_files
  if [[ "$run_succeeded" != 1 && "$created_output" == 1 &&
        -d "$output_directory" && ! -L "$output_directory" ]]; then
    if [[ -n "$output_identity" &&
          "$(identity_of "$output_directory" 2>/dev/null)" == "$output_identity" ]]; then
      rm -rf "$output_directory"
    elif [[ -z "$output_identity" &&
            "$(owner_of "$output_directory" 2>/dev/null)" == "$(id -u)" &&
            "$(mode_of "$output_directory" 2>/dev/null)" == 700 ]]; then
      rm -rf "$output_directory"
    fi
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

mkdir -m 700 "$output_directory"
created_output=1
output_identity="$(identity_of "$output_directory")"
[[ "$(owner_of "$output_directory")" == "$(id -u)" ]] ||
  fail "OUTPUT_DIRECTORY must be owned by the current user"
[[ "$(mode_of "$output_directory")" == "700" ]] ||
  fail "OUTPUT_DIRECTORY must have mode 0700"

replay_token="$(
  "$python_bin" - "$token_file" <<'PY'
import pathlib
import sys

data = pathlib.Path(sys.argv[1]).read_bytes()
if data.endswith(b"\n"):
    data = data[:-1]
if not 1 <= len(data) <= 4096:
    raise SystemExit("TOKEN_FILE must contain 1...4096 token bytes")
if any(byte < 0x21 or byte > 0x7e for byte in data):
    raise SystemExit("TOKEN_FILE must contain exactly one printable non-space ASCII token")
sys.stdout.buffer.write(data)
PY
)"
printf 'Authorization: Token %s\n' "$replay_token" >"$auth_header"
chmod 600 "$auth_header"
[[ "$(mode_of "$auth_header")" == "600" ]] ||
  fail "generated authorization header must have mode 0600"

curl_authenticated() {
  "$curl_bin" --fail-with-body --silent --show-error \
    --header "@$auth_header" "$@"
}

import_checkpoint() {
  local destination="$1"
  curl_authenticated \
    --output "$destination" \
    --form "debugFile=@${checkpoint_path};type=application/json" \
    --form "investigatorId=${ARKHAM_REPLAY_INVESTIGATOR_ID}" \
    "${server_base}/api/v1/arkham/games/import?multiplayerVariant=WithFriends"
}

json_uuid() {
  "$python_bin" - "$1" "$2" <<'PY'
import json
import pathlib
import sys
import uuid

value = json.loads(pathlib.Path(sys.argv[1]).read_bytes())[sys.argv[2]]
if not isinstance(value, str):
    raise SystemExit(f"{sys.argv[2]} must be a string")
parsed = uuid.UUID(value)
canonical = str(parsed)
if value != canonical:
    raise SystemExit(f"{sys.argv[2]} must be a canonical lowercase UUID")
print(canonical)
PY
}

import_checkpoint "$damage_import"
damage_game_id="$(json_uuid "$damage_import" id)"
curl_authenticated --output "$damage_game" \
  "${server_base}/api/v1/arkham/games/${damage_game_id}"
damage_player_id="$(json_uuid "$damage_game" playerId)"

import_checkpoint "$horror_import"
horror_game_id="$(json_uuid "$horror_import" id)"
curl_authenticated --output "$horror_game" \
  "${server_base}/api/v1/arkham/games/${horror_game_id}"
horror_player_id="$(json_uuid "$horror_game" playerId)"
[[ "$damage_game_id" != "$horror_game_id" ]] ||
  fail "checkpoint imports must create distinct games"

trusted_top_level="$(
  env -i \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_TERMINAL_PROMPT=0 \
    HOME=/nonexistent \
    LANG=C \
    LC_ALL=C \
    PATH=/usr/bin:/bin \
    "$git_bin" -C "$repo_root" rev-parse --show-toplevel
)"
trusted_top_level="$(cd "$trusted_top_level" && pwd -P)"
[[ "$trusted_top_level" == "$repo_root" ]] ||
  fail "Git top-level does not match the Apple repository root"
apple_revision="$(
  env -i \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_TERMINAL_PROMPT=0 \
    HOME=/nonexistent \
    LANG=C \
    LC_ALL=C \
    PATH=/usr/bin:/bin \
    "$git_bin" -C "$repo_root" rev-parse HEAD
)"
[[ "$apple_revision" =~ ^[0-9a-f]{40}$ ]] ||
  fail "Apple HEAD is not a full lowercase Git revision"

export ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_DEADLINE_SECONDS="${ARKHAM_REPLAY_DEADLINE_SECONDS:-60}"
export ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_SERVER_BASE_URL="$server_base"
export ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_SERVER_PROFILE_ID="${ARKHAM_REPLAY_SERVER_PROFILE_ID:-00000000-0000-0000-0000-000000000777}"
export ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_AUTH_TOKEN="$replay_token"
export ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_EXPECTED_APPLE_REVISION="$apple_revision"
export ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_EXPECTED_CONTRACT_REVISION="$ARKHAM_REPLAY_EXPECTED_CONTRACT_REVISION"
export ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_EXPECTED_CATALOG_REVISION="$ARKHAM_REPLAY_EXPECTED_CATALOG_REVISION"
export ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_EXPECTED_STARTING_PROMPT_ENEMY_ID="$ARKHAM_REPLAY_ENEMY_ID"
export ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_EXPECTED_STARTING_PROMPT_INVESTIGATOR_ID="$ARKHAM_REPLAY_INVESTIGATOR_ID"
export ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_CHECKPOINT_ARTIFACT_PATH="$checkpoint_path"

run_case() {
  export ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_CASE="$1"
  export ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_GAME_ID="$2"
  export ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_PLAYER_ID="$3"
  export ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_RESULT_PATH="$4"
  (
    cd "$repo_root"
    "$swift_bin" test \
      --package-path "$repo_root/Packages/ArkhamHorrorShared" \
      --no-parallel \
      --filter AssignmentContinuationReplayDriverSuite
  )
}

run_case \
  damage-first-then-remaining-horror \
  "$damage_game_id" \
  "$damage_player_id" \
  "$damage_evidence"
run_case \
  horror-first-then-remaining-damage \
  "$horror_game_id" \
  "$horror_player_id" \
  "$horror_evidence"

unset replay_token ARKHAM_PRODUCTION_ASSIGNMENT_REPLAY_AUTH_TOKEN
cleanup_runtime_files

"$python_bin" - \
  "$checkpoint_path" \
  "$output_directory" \
  "$damage_evidence" "$damage_game_id" "$damage_player_id" \
  "$horror_evidence" "$horror_game_id" "$horror_player_id" \
  "$apple_revision" \
  "$ARKHAM_REPLAY_EXPECTED_CONTRACT_REVISION" \
  "$ARKHAM_REPLAY_EXPECTED_CATALOG_REVISION" \
  "$ARKHAM_REPLAY_ENEMY_ID" \
  "$ARKHAM_REPLAY_INVESTIGATOR_ID" <<'PY'
import hashlib
import json
import os
import pathlib
import re
import stat
import sys

checkpoint_path = pathlib.Path(sys.argv[1])
output_directory = pathlib.Path(sys.argv[2])
cases = [
    (
        pathlib.Path(sys.argv[3]),
        sys.argv[4],
        sys.argv[5],
        "damage-first-then-remaining-horror",
        0,
        "damage",
        "horror",
    ),
    (
        pathlib.Path(sys.argv[6]),
        sys.argv[7],
        sys.argv[8],
        "horror-first-then-remaining-damage",
        1,
        "horror",
        "damage",
    ),
]
expected_apple = sys.argv[9]
expected_contract = sys.argv[10]
expected_catalog = sys.argv[11]
expected_enemy = sys.argv[12]
expected_investigator = sys.argv[13]

def reject_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result

def decode_exact(data):
    return json.loads(data, object_pairs_hook=reject_duplicates)

def canonical(value):
    return json.dumps(
        value,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode()

expected_files = {"damage-first.json", "horror-first.json"}
if set(os.listdir(output_directory)) != expected_files:
    raise SystemExit("output directory must contain exactly two fresh evidence files")

checkpoint_bytes = checkpoint_path.read_bytes()
checkpoint_sha = hashlib.sha256(checkpoint_bytes).hexdigest()
checkpoint = decode_exact(checkpoint_bytes)["replayCheckpoint"]
provenance = checkpoint["provenance"]
checkpoint_identity = provenance["checkpoint"]
envelope_sha = checkpoint["envelopeSha256"]

for path, game_id, player_id, case_name, source_index, selected, remaining in cases:
    file_info = path.lstat()
    if not stat.S_ISREG(file_info.st_mode) or file_info.st_nlink != 1:
        raise SystemExit(f"{path.name} must be a single-link regular file")
    if file_info.st_uid != os.geteuid() or file_info.st_mode & 0o022:
        raise SystemExit(f"{path.name} must be current-user-owned and not writable by group/world")
    data = path.read_bytes()
    artifact = decode_exact(data)
    if canonical(artifact) != data:
        raise SystemExit(f"{path.name} is not compact canonical JSON")
    if set(artifact) != {"evidence", "evidenceCanonicalSHA256"}:
        raise SystemExit(f"{path.name} has an unexpected artifact shape")
    evidence = artifact["evidence"]
    if hashlib.sha256(canonical(evidence)).hexdigest() != artifact["evidenceCanonicalSHA256"]:
        raise SystemExit(f"{path.name} has an invalid evidence digest")
    if evidence["schemaVersion"] != "2.0.0":
        raise SystemExit(f"{path.name} has an unsupported evidence schema")
    if set(evidence) != {
        "schemaVersion",
        "checkpoint",
        "source",
        "answer",
        "controller",
        "assignmentBefore",
        "assignmentAfter",
        "assignmentDelta",
        "nextPrompt",
        "revisions",
    }:
        raise SystemExit(f"{path.name} has an unexpected evidence shape")
    observed_checkpoint = evidence["checkpoint"]
    if set(observed_checkpoint) != {
        "caseName",
        "name",
        "playerID",
        "questionVersion",
        "promptCanonicalSHA256",
        "artifactSHA256",
        "envelopeSHA256",
    }:
        raise SystemExit(f"{path.name} has an unexpected checkpoint shape")
    if observed_checkpoint["caseName"] != case_name:
        raise SystemExit(f"{path.name} records the wrong replay case")
    if observed_checkpoint["artifactSHA256"] != checkpoint_sha:
        raise SystemExit(f"{path.name} does not bind the exact checkpoint file")
    if observed_checkpoint["envelopeSHA256"] != envelope_sha:
        raise SystemExit(f"{path.name} does not bind the checkpoint envelope")
    if observed_checkpoint["name"] != checkpoint_identity["name"]:
        raise SystemExit(f"{path.name} records the wrong checkpoint name")
    if observed_checkpoint["playerID"] != checkpoint_identity["playerId"]:
        raise SystemExit(f"{path.name} records the wrong checkpoint player")
    if observed_checkpoint["questionVersion"] != checkpoint_identity["questionVersion"]:
        raise SystemExit(f"{path.name} records the wrong checkpoint version")
    if observed_checkpoint["promptCanonicalSHA256"] != checkpoint_identity["promptSha256"]:
        raise SystemExit(f"{path.name} records the wrong checkpoint prompt digest")
    source = evidence["source"]
    answer = evidence["answer"]
    if set(source) != {
        "gameID",
        "playerID",
        "promptTag",
        "sourceTag",
        "enemyID",
        "investigatorID",
        "promptVersion",
        "promptCanonicalSHA256",
        "selectedAssignment",
        "sourceIndex",
    }:
        raise SystemExit(f"{path.name} has an unexpected source shape")
    if source["gameID"] != game_id or source["playerID"] != player_id:
        raise SystemExit(f"{path.name} records the wrong imported game/player")
    if source["enemyID"] != expected_enemy or source["investigatorID"] != expected_investigator:
        raise SystemExit(f"{path.name} records the wrong prompt identity")
    if source["promptTag"] != "QuestionWithSource" or source["sourceTag"] != "EnemyAttackSource":
        raise SystemExit(f"{path.name} records the wrong prompt/source tag")
    if source["promptVersion"] != checkpoint_identity["questionVersion"]:
        raise SystemExit(f"{path.name} records the wrong source prompt version")
    if source["promptCanonicalSHA256"] != checkpoint_identity["promptSha256"]:
        raise SystemExit(f"{path.name} records the wrong source prompt digest")
    if source["selectedAssignment"] != selected:
        raise SystemExit(f"{path.name} records the wrong selected assignment")
    if source["sourceIndex"] != source_index:
        raise SystemExit(f"{path.name} records the wrong semantic source index")
    if set(answer) != {"tag", "contents"}:
        raise SystemExit(f"{path.name} has an unexpected answer shape")
    if answer["tag"] != "Answer":
        raise SystemExit(f"{path.name} records the wrong answer envelope")
    answer_contents = answer["contents"]
    if set(answer_contents) != {"choice", "playerId", "questionVersion"}:
        raise SystemExit(f"{path.name} has unexpected answer contents")
    if answer_contents["choice"] != source_index or answer_contents["playerId"] != player_id:
        raise SystemExit(f"{path.name} records the wrong submitted answer")
    if answer_contents["questionVersion"] != checkpoint_identity["questionVersion"]:
        raise SystemExit(f"{path.name} records the wrong answer version")
    next_prompt = evidence["nextPrompt"]
    if set(next_prompt) != {
        "promptTag",
        "sourceTag",
        "assignment",
        "version",
        "canonicalSHA256",
    }:
        raise SystemExit(f"{path.name} has an unexpected next-prompt shape")
    if (
        next_prompt["promptTag"] != "QuestionWithSource"
        or next_prompt["sourceTag"] != "EnemyAttackSource"
        or next_prompt["assignment"] != remaining
        or next_prompt["version"] != checkpoint_identity["questionVersion"] + 1
        or re.fullmatch(r"[0-9a-f]{64}", next_prompt["canonicalSHA256"]) is None
    ):
        raise SystemExit(f"{path.name} records the wrong authoritative next prompt")
    revisions = evidence["revisions"]
    if set(revisions) != {"serverBuild", "game", "apple", "contract", "catalog"}:
        raise SystemExit(f"{path.name} has an unexpected revisions shape")
    if revisions["game"] != provenance["sourceGameGitRevision"]:
        raise SystemExit(f"{path.name} records the wrong imported game revision")
    if (
        revisions["apple"] != expected_apple
        or revisions["contract"] != expected_contract
        or revisions["contract"] != provenance["contractSchemaRevision"]
        or revisions["catalog"] != expected_catalog
    ):
        raise SystemExit(f"{path.name} records the wrong checkpoint contract")
    server_build = revisions["serverBuild"]
    if set(server_build) != {
        "gitRevision",
        "gitTree",
        "sourceSha256",
        "sourceClean",
        "attestation",
    }:
        raise SystemExit(f"{path.name} has an unexpected server-build shape")
    if (
        server_build["attestation"] != "git-clean"
        or server_build["sourceClean"] is not True
        or re.fullmatch(r"[0-9a-f]{40}", server_build["gitRevision"]) is None
        or re.fullmatch(r"[0-9a-f]{40}", server_build["gitTree"]) is None
        or re.fullmatch(r"[0-9a-f]{64}", server_build["sourceSha256"]) is None
    ):
        raise SystemExit(f"{path.name} records an invalid server build identity")
PY

run_succeeded=1
printf 'Verified fresh production replay evidence:\n  %s\n  %s\n' \
  "$damage_evidence" "$horror_evidence"
