#!/bin/sh
# Verifies the locale-catalog artifacts against the exact backend commit pinned by
# ContractPin.current.
set -eu

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture_root="$repo_root/Packages/ArkhamHorrorShared/Tests/ArkhamHorrorSharedTests/Fixtures/LocaleCatalog"
backend_repo_url="${LOCALE_CATALOG_BACKEND_REPO_URL:-https://github.com/djensenius/ArkhamHorror.git}"
contract_pin_file="$repo_root/Packages/ArkhamHorrorShared/Sources/ArkhamHorrorShared/Domain/Contract/ContractPin.swift"
backend_commit="${LOCALE_CATALOG_BACKEND_COMMIT:-}"
scratch_dir="$repo_root/.build/locale-catalog-provenance"

mappings="
Contract/manifest.json:contracts/manifest.json
Contract/capabilities-locale-catalog.json:contracts/fixtures/capabilities-locale-catalog.json
Contract/locale-catalog-backend-registry.json:contracts/fixtures/locale-catalog-backend-registry.json
Contract/locale-catalog-manifest.json:contracts/fixtures/locale-catalog-manifest.json
Contract/locale-catalog-chunk-d951fedc2b5f0644bb126beb77f6e03a2abad3627c274985e9b8a42b09116693.json:contracts/fixtures/locale-catalog-chunk-d951fedc2b5f0644bb126beb77f6e03a2abad3627c274985e9b8a42b09116693.json
Contract/locale-catalog-chunk-2efb9d458b5dd9b7ae9a284c277ca68e47a40212c95ce85da5b50f598d9fc448.json:contracts/fixtures/locale-catalog-chunk-2efb9d458b5dd9b7ae9a284c277ca68e47a40212c95ce85da5b50f598d9fc448.json
Contract/locale-catalog-chunk-309d63c6b0ab62a2fc4bc993860a820b05c156f2e7d67439a24b487839df1488.json:contracts/fixtures/locale-catalog-chunk-309d63c6b0ab62a2fc4bc993860a820b05c156f2e7d67439a24b487839df1488.json
Contract/locale-catalog-chunk-932fbfdd3570550d2bd7255599e7b54cb8ceac12d4597686613d97254b67c12d.json:contracts/fixtures/locale-catalog-chunk-932fbfdd3570550d2bd7255599e7b54cb8ceac12d4597686613d97254b67c12d.json
Contract/locale-catalog-source-de.json:contracts/fixtures/locale-catalog-source-de.json
Contract/locale-catalog-source-en.json:contracts/fixtures/locale-catalog-source-en.json
Contract/locale-catalog-source-pt-BR.json:contracts/fixtures/locale-catalog-source-pt-BR.json
Schemas/capabilities.schema.json:contracts/schemas/capabilities.schema.json
Schemas/manifest.schema.json:frontend/schemas/locale-catalog/v1/manifest.schema.json
Schemas/chunk.schema.json:frontend/schemas/locale-catalog/v1/chunk.schema.json
"

if [ ! -d "$fixture_root" ]; then
  echo "error: locale catalog fixture directory is missing: $fixture_root" >&2
  exit 1
fi
if [ -z "$backend_commit" ]; then
  backend_commit=$(grep -o 'backendCommit: "[0-9a-f]\{40\}"' "$contract_pin_file" | head -n1 | sed 's/.*"\([0-9a-f]*\)"/\1/')
fi
if ! printf '%s\n' "$backend_commit" | grep -Eq '^[0-9a-f]{40}$'; then
  echo "error: could not determine a 40-character backend commit" >&2
  exit 1
fi

rm -rf "$scratch_dir"
mkdir -p "$scratch_dir"
trap 'rm -rf "$scratch_dir"' EXIT HUP INT TERM

git init -q "$scratch_dir"
git -C "$scratch_dir" remote add origin "$backend_repo_url"
git -C "$scratch_dir" fetch -q --depth 1 origin "$backend_commit"
if [ "$(git -C "$scratch_dir" rev-parse FETCH_HEAD)" != "$backend_commit" ]; then
  echo "error: FETCH_HEAD does not match pinned commit $backend_commit" >&2
  exit 1
fi

expected_local_names=$(
  for mapping in $mappings; do
    echo "${mapping%%:*}"
  done | sort
)
actual_local_names=$(
  cd "$fixture_root"
  find . -type f -name '*.json' -print | sed 's#^\./##' | sort
)
if [ "$expected_local_names" != "$actual_local_names" ]; then
  echo "error: locale-catalog fixture path set differs from the governed map" >&2
  exit 1
fi

for mapping in $mappings; do
  local_path="${mapping%%:*}"
  backend_path="${mapping#*:}"
  local_file="$fixture_root/$local_path"
  expected_file="$scratch_dir/expected.json"
  tree_record=$(git -C "$scratch_dir" ls-tree FETCH_HEAD -- "$backend_path")
  if [ "$(echo "$tree_record" | awk '{print $1}')" != "100644" ] \
    || [ "$(echo "$tree_record" | awk '{print $2}')" != "blob" ]; then
    echo "error: $backend_path is not a regular backend blob" >&2
    exit 1
  fi
  git -C "$scratch_dir" show "FETCH_HEAD:$backend_path" > "$expected_file"
  if ! cmp -s "$local_file" "$expected_file"; then
    echo "error: $local_path differs from $backend_path at $backend_commit" >&2
    exit 1
  fi
done

echo "All locale-catalog artifacts match backend commit $backend_commit exactly."
