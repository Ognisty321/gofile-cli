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

FOLDER_UUID="9f8e7d6c-5b4a-3928-1716-151413121110"
FILE_UUID="d4c5e6f7-a8b9-4c0d-9e1f-2a3b4c5d6e7f"
LINK_UUID="7a8b9c0d-1e2f-4a3b-9c4d-5e6f7a8b9c0d"

# Helpers for inspecting the arguments captured by the curl mock.
curl_args=()
load_curl_args() {
  mapfile -d '' -t curl_args <"$CURL_ARGS_FILE" || true
}

curl_has_arg() {
  printf '%s\n' "${curl_args[@]}" | grep -Fx -- "$1" >/dev/null
}

curl_payload() {
  local i
  for ((i = 0; i < ${#curl_args[@]}; i++)); do
    if [[ "${curl_args[$i]}" == "-d" ]]; then
      printf '%s\n' "${curl_args[$((i + 1))]}"
      return 0
    fi
  done
}

bash -n "$SCRIPT"

help_config="$TMP_DIR/help-config"
GOFILE_CONFIG_DIR="$help_config" bash "$SCRIPT" --help >/dev/null
[[ ! -e "$help_config" ]] || fail "--help created a config directory"

[[ "$(bash "$SCRIPT" --version)" == "gofile.sh v2.2.0" ]] || fail "unexpected version output"
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
printf '{"status":"ok","data":{"id":"d4c5e6f7-a8b9-4c0d-9e1f-2a3b4c5d6e7f","type":"file","name":"sample.txt","parentFolder":"9f8e7d6c-5b4a-3928-1716-151413121110","downloadPage":"https://gofile.io/d/x7k2p9Qm","guestToken":"guest-test"}}\n200'
EOF
chmod +x "$TMP_DIR/bin/curl"

export PATH="$TMP_DIR/bin:$PATH"
export CURL_ARGS_FILE="$TMP_DIR/curl-args"

GOFILE_TOKEN="token" bash "$SCRIPT" --compact create-folder "$FOLDER_UUID" --public true >/dev/null
load_curl_args
curl_payload | jq -e --arg id "$FOLDER_UUID" \
  '.parentFolderId == $id and .public == true and (has("folderName") | not)' >/dev/null ||
  fail "create-folder built an invalid payload"

# Mutations need UUIDs: a share code must trigger a warning.
warning="$(GOFILE_TOKEN="token" bash "$SCRIPT" --compact create-folder AbCdEf 2>&1 >/dev/null)"
assert_contains "$warning" "is not a UUID"
warning="$(GOFILE_TOKEN="token" bash "$SCRIPT" --compact create-folder "$FOLDER_UUID" 2>&1 >/dev/null)"
[[ -z "$warning" ]] || fail "a UUID triggered a warning: $warning"

sample_file="$TMP_DIR/sample;special.txt"
printf 'sample\n' >"$sample_file"
GOFILE_CONFIG_DIR="$TMP_DIR/guest-config" bash "$SCRIPT" --guest --compact upload "$sample_file" \
  --folder "$FOLDER_UUID" --region eu-par --json >/dev/null
load_curl_args
curl_has_arg "folderId=$FOLDER_UUID" || fail "upload did not send the folder ID"
printf '%s\n' "${curl_args[@]}" | grep -F 'file=@"' >/dev/null ||
  fail "upload did not quote the multipart file path"
printf '%s\n' "${curl_args[@]}" | grep -Fx 'https://upload-eu-par.gofile.io/uploadfile' >/dev/null ||
  fail "upload did not use the selected regional endpoint"

second_file="$TMP_DIR/second.txt"
printf 'second\n' >"$second_file"
GOFILE_CONFIG_DIR="$TMP_DIR/guest-config" bash "$SCRIPT" --guest --compact upload \
  "$sample_file" "$second_file" --json >/dev/null
load_curl_args
curl_has_arg "folderId=$FOLDER_UUID" ||
  fail "multiple guest uploads did not reuse the returned folder"
printf '%s\n' "${curl_args[@]}" | grep -Fx 'Authorization: Bearer guest-test' >/dev/null ||
  fail "multiple guest uploads did not reuse the returned guest token"

upload_output="$(GOFILE_CONFIG_DIR="$TMP_DIR/guest-config" bash "$SCRIPT" --guest upload "$sample_file" --region na-nyc)"
assert_contains "$upload_output" "id: $FILE_UUID"
assert_contains "$upload_output" "https://gofile.io/d/x7k2p9Qm"
load_curl_args
curl_has_arg 'https://upload-na-nyc.gofile.io/uploadfile' || fail "upload did not accept the na-nyc region"
GOFILE_CONFIG_DIR="$TMP_DIR/guest-config" bash "$SCRIPT" --guest upload "$sample_file" --region ap-syd >/dev/null
if GOFILE_CONFIG_DIR="$TMP_DIR/guest-config" bash "$SCRIPT" --guest upload "$sample_file" --region xx-bad >/dev/null 2>&1; then
  fail "an unknown region was accepted"
fi

if GOFILE_TOKEN="token" bash "$SCRIPT" upload "$sample_file" --url "https://example.com/upload" >/dev/null 2>&1; then
  fail "custom URL accepted an account token"
fi
GOFILE_TOKEN="token" bash "$SCRIPT" --compact upload "$sample_file" \
  --url "https://example.com/upload" --allow-custom-auth --json >/dev/null
load_curl_args
printf '%s\n' "${curl_args[@]}" | grep -Fx 'Authorization: Bearer token' >/dev/null ||
  fail "--allow-custom-auth did not pass the explicitly authorized token"

if bash "$SCRIPT" upload "$sample_file" --region eu-par --zone eu >/dev/null 2>&1; then
  fail "mutually exclusive endpoint options were accepted"
fi

if GOFILE_TOKEN="token" bash "$SCRIPT" move-content source-id destination-id --password secret >/dev/null 2>&1; then
  fail "move-content accepted an unsupported password option"
fi

# update-content
GOFILE_TOKEN="token" bash "$SCRIPT" update-content "$FOLDER_UUID" password secret >/dev/null
load_curl_args
curl_payload | jq -e '.attribute == "password" and
  .attributeValue == "2bb80d537b1da3e38bd30361aa855686bde0eacd7162fef6a25fe97bf527a25b"' >/dev/null ||
  fail "update-content did not send the SHA-256 hash of the password"
GOFILE_TOKEN="token" bash "$SCRIPT" update-content "$FOLDER_UUID" password "" >/dev/null
load_curl_args
curl_payload | jq -e '.attributeValue == ""' >/dev/null || fail "an empty password was not sent as a removal"
if GOFILE_TOKEN="token" bash "$SCRIPT" update-content "$FOLDER_UUID" password abc >/dev/null 2>&1; then
  fail "a password shorter than 4 characters was accepted"
fi

GOFILE_TOKEN="token" bash "$SCRIPT" update-content "$FOLDER_UUID" expiry 1786051200 --delete-after-expiry >/dev/null
load_curl_args
curl_payload | jq -e '.attribute == "expiry" and .attributeValue == 1786051200 and .deleteAfterExpiry == true' >/dev/null ||
  fail "update-content built an invalid expiry payload"
GOFILE_TOKEN="token" bash "$SCRIPT" update-content "$FOLDER_UUID" expiry "" >/dev/null
load_curl_args
curl_payload | jq -e '.attributeValue == "" and (has("deleteAfterExpiry") | not)' >/dev/null ||
  fail "an empty expiry was not sent as a removal"

GOFILE_TOKEN="token" bash "$SCRIPT" update-content "$FILE_UUID" modTime 1754512800 >/dev/null
load_curl_args
curl_payload | jq -e '.attribute == "modTime" and .attributeValue == 1754512800' >/dev/null ||
  fail "update-content did not support modTime"
curl_has_arg "https://api.gofile.io/contents/$FILE_UUID/update" || fail "update-content used the wrong URL"
if GOFILE_TOKEN="token" bash "$SCRIPT" update-content "$FILE_UUID" bogus value >/dev/null 2>&1; then
  fail "update-content accepted an unknown attribute"
fi

# get-content / ls / search-content query parameters
GOFILE_TOKEN="token" bash "$SCRIPT" get-content "https://gofile.io/d/x7k2p9Qm" --page 2 --page-size 50 \
  --sort-field name --sort-direction desc --filter "my docs" --max-depth 3 --password secret >/dev/null
load_curl_args
for expected in 'https://api.gofile.io/contents/x7k2p9Qm' 'page=2' 'pageSize=50' 'sortField=name' \
  'sortDirection=-1' 'contentFilter=my docs' 'maxdepth=3' \
  'password=2bb80d537b1da3e38bd30361aa855686bde0eacd7162fef6a25fe97bf527a25b'; do
  curl_has_arg "$expected" || fail "get-content did not send '$expected'"
done
if GOFILE_TOKEN="token" bash "$SCRIPT" get-content "$FOLDER_UUID" --max-depth 17 >/dev/null 2>&1; then
  fail "get-content accepted an out-of-range --max-depth"
fi

ls_output="$(GOFILE_TOKEN="token" bash "$SCRIPT" ls "$FILE_UUID")"
assert_contains "$ls_output" "$FILE_UUID  sample.txt"

GOFILE_TOKEN="token" bash "$SCRIPT" search-content "$FOLDER_UUID" "music files" \
  --created-from 1754512800 --created-to 1786051200 >/dev/null
load_curl_args
for expected in "contentId=$FOLDER_UUID" 'searchedString=music files' 'createTimeFrom=1754512800' \
  'createTimeTo=1786051200'; do
  curl_has_arg "$expected" || fail "search-content did not send '$expected'"
done

# Direct links: "" skips a field, "none" clears it on update.
GOFILE_TOKEN="token" bash "$SCRIPT" create-direct-link "$FILE_UUID" 1786051200 "203.0.113.10,198.51.100.2" "" "jane:s3cret" >/dev/null
load_curl_args
curl_payload | jq -e '.expireTime == 1786051200 and .sourceIpsAllowed == ["203.0.113.10", "198.51.100.2"] and
  .auth == ["jane:s3cret"] and (has("domainsAllowed") | not) and (has("domainsBlocked") | not)' >/dev/null ||
  fail "create-direct-link built an invalid payload"

GOFILE_TOKEN="token" bash "$SCRIPT" update-direct-link "$FILE_UUID" "$LINK_UUID" none none "" "" "bad.com" >/dev/null
load_curl_args
curl_payload | jq -e '.expireTime == 4102444800 and .sourceIpsAllowed == [] and .domainsBlocked == ["bad.com"] and
  (has("domainsAllowed") | not) and (has("auth") | not)' >/dev/null ||
  fail "update-direct-link built an invalid payload"
curl_has_arg "https://api.gofile.io/contents/$FILE_UUID/directlinks/$LINK_UUID" ||
  fail "update-direct-link used the wrong URL"
if GOFILE_TOKEN="token" bash "$SCRIPT" update-direct-link "$FILE_UUID" "$LINK_UUID" >/dev/null 2>&1; then
  fail "update-direct-link accepted an empty update"
fi

# create-account must not send a token.
GOFILE_TOKEN="token" bash "$SCRIPT" create-account >/dev/null
load_curl_args
curl_has_arg 'https://api.gofile.io/accounts' || fail "create-account used the wrong URL"
[[ "$(curl_payload)" == "{}" ]] || fail "create-account without an email must send an empty object"
if curl_has_arg 'Authorization: Bearer token'; then
  fail "create-account sent the existing token"
fi
GOFILE_TOKEN="token" bash "$SCRIPT" create-account jane@example.com >/dev/null
load_curl_args
curl_payload | jq -e '.email == "jane@example.com"' >/dev/null || fail "create-account did not send the email"

# API errors must fail, including an error status delivered with HTTP 200.
cat >"$TMP_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"status":"error-notPremium"}\n200'
EOF
if error_output="$(GOFILE_TOKEN="token" bash "$SCRIPT" get-content "$FOLDER_UUID" 2>&1)"; then
  fail "an error status with HTTP 200 was treated as success"
fi
assert_contains "$error_output" "API status=error-notPremium"
assert_contains "$error_output" "Premium"

cat >"$TMP_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"status":"error-token"}\n401'
EOF
if error_output="$(GOFILE_TOKEN="token" bash "$SCRIPT" get-account-id 2>&1)"; then
  fail "HTTP 401 was treated as success"
fi
assert_contains "$error_output" "HTTP 401"
assert_contains "$error_output" "error-token"

printf 'All smoke tests passed.\n'
