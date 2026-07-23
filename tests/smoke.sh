#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/gofile.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "expected '$needle' in '$haystack'"
}

bash -n "$SCRIPT"

help_config="$TMP_DIR/help-config"
GOFILE_CONFIG_DIR="$help_config" bash "$SCRIPT" --help >/dev/null
[[ ! -e "$help_config" ]] || fail "--help created a config directory"

[[ "$(bash "$SCRIPT" --version)" == "gofile.sh v2.1.0" ]] || fail "unexpected version output"
[[ "$(bash "$SCRIPT" hash-password abc)" == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" ]] ||
  fail "SHA-256 output is incorrect"

config_dir="$TMP_DIR/config"
GOFILE_CONFIG_DIR="$config_dir" bash "$SCRIPT" set-token "test-token" >/dev/null
token_output="$(GOFILE_CONFIG_DIR="$config_dir" bash "$SCRIPT" show-token)"
assert_contains "$token_output" "test…oken"
GOFILE_CONFIG_DIR="$config_dir" bash "$SCRIPT" unset-token >/dev/null
[[ -z "$(awk -F= '/^API_TOKEN=/{print $2}' "$config_dir/config")" ]] || fail "token was not removed"

mkdir -p "$TMP_DIR/bin"
cat >"$TMP_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${CURL_ARGS_FILE:?}"
: >"$CURL_ARGS_FILE"
printf '%s\0' "$@" >"$CURL_ARGS_FILE"
printf '{"status":"ok","data":{"fileName":"sample.txt","fileId":"file-1","folderId":"folder-1","guestToken":"guest-test"}}\n200'
EOF
chmod +x "$TMP_DIR/bin/curl"

export PATH="$TMP_DIR/bin:$PATH"
export CURL_ARGS_FILE="$TMP_DIR/curl-args"

GOFILE_TOKEN="token" bash "$SCRIPT" --compact create-folder parent-id --public true >/dev/null
mapfile -d '' -t curl_args <"$CURL_ARGS_FILE" || true
payload=""
for ((i = 0; i < ${#curl_args[@]}; i++)); do
  if [[ "${curl_args[$i]}" == "-d" ]]; then
    payload="${curl_args[$((i + 1))]}"
    break
  fi
done
jq -e '.parentFolderId == "parent-id" and .public == true and (has("folderName") | not)' <<<"$payload" >/dev/null ||
  fail "create-folder built an invalid payload"

sample_file="$TMP_DIR/sample;special.txt"
printf 'sample\n' >"$sample_file"
GOFILE_CONFIG_DIR="$TMP_DIR/guest-config" bash "$SCRIPT" --guest --compact upload "$sample_file" \
  --folder "https://gofile.io/d/AbCdEf" --region eu-par --json >/dev/null
mapfile -d '' -t curl_args <"$CURL_ARGS_FILE" || true
printf '%s\n' "${curl_args[@]}" | grep -Fx 'folderId=AbCdEf' >/dev/null ||
  fail "upload did not extract the folder ID from a share URL"
printf '%s\n' "${curl_args[@]}" | grep -F 'file=@"' >/dev/null ||
  fail "upload did not quote the multipart file path"
printf '%s\n' "${curl_args[@]}" | grep -Fx 'https://upload-eu-par.gofile.io/uploadfile' >/dev/null ||
  fail "upload did not use the selected regional endpoint"

second_file="$TMP_DIR/second.txt"
printf 'second\n' >"$second_file"
GOFILE_CONFIG_DIR="$TMP_DIR/guest-config" bash "$SCRIPT" --guest --compact upload \
  "$sample_file" "$second_file" --json >/dev/null
mapfile -d '' -t curl_args <"$CURL_ARGS_FILE" || true
printf '%s\n' "${curl_args[@]}" | grep -Fx 'folderId=folder-1' >/dev/null ||
  fail "multiple guest uploads did not reuse the returned folder"
printf '%s\n' "${curl_args[@]}" | grep -Fx 'Authorization: Bearer guest-test' >/dev/null ||
  fail "multiple guest uploads did not reuse the returned guest token"

if GOFILE_TOKEN="token" bash "$SCRIPT" upload "$sample_file" --url "https://example.com/upload" >/dev/null 2>&1; then
  fail "custom URL accepted an account token"
fi
GOFILE_TOKEN="token" bash "$SCRIPT" --compact upload "$sample_file" \
  --url "https://example.com/upload" --allow-custom-auth --json >/dev/null
mapfile -d '' -t curl_args <"$CURL_ARGS_FILE" || true
printf '%s\n' "${curl_args[@]}" | grep -Fx 'Authorization: Bearer token' >/dev/null ||
  fail "--allow-custom-auth did not pass the explicitly authorized token"

if bash "$SCRIPT" upload "$sample_file" --region eu-par --zone eu >/dev/null 2>&1; then
  fail "mutually exclusive endpoint options were accepted"
fi

if GOFILE_TOKEN="token" bash "$SCRIPT" move-content source-id destination-id --password secret >/dev/null 2>&1; then
  fail "move-content accepted an unsupported password option"
fi

printf 'All smoke tests passed.\n'
