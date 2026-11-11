#!/usr/bin/env bash
#
# gofile.sh - A more robust Bash CLI for the Gofile.io API
#
# Requires: bash, curl, jq
#
# Notes:
# - Defaults to the official global upload endpoint:
#     POST https://upload.gofile.io/uploadfile
# - Supports official regional upload proxies and a legacy --server option.
# - API reference: https://gofile.io/api
#
# License: MIT (same spirit as original)
#

set -euo pipefail
IFS=$'\n\t'

VERSION="2.2.0"

# --------------------------------------------------
# Config (XDG-friendly)
# --------------------------------------------------

XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
CONFIG_DIR="${GOFILE_CONFIG_DIR:-$XDG_CONFIG_HOME/gofile-cli}"
CONFIG_FILE="${GOFILE_CONFIG_FILE:-$CONFIG_DIR/config}"

API_BASE="${GOFILE_API_BASE:-https://api.gofile.io}"
API_BASE="${API_BASE%/}"
UPLOAD_URL_DEFAULT="${GOFILE_UPLOAD_URL:-https://upload.gofile.io/uploadfile}"
CURL_CONNECT_TIMEOUT="${GOFILE_CONNECT_TIMEOUT:-15}"
CURL_MAX_TIME="${GOFILE_MAX_TIME:-0}"

# --------------------------------------------------
# Global flags
# --------------------------------------------------

UPLOAD_REGIONS="eu-par na-phx na-nyc ap-sgp ap-hkg ap-tyo ap-syd sa-sao"
DIRECT_LINK_NEVER_EXPIRES=4102444800   # "never expires" sentinel documented by the API

OUTPUT_MODE="pretty"   # pretty|compact|raw
VERBOSE=0
CLI_TOKEN=""           # optional override via --token
NO_AUTH=0              # if 1, do not send Authorization even if token exists (guest mode)

# --------------------------------------------------
# Small helpers
# --------------------------------------------------

say() { printf '%s\n' "$*"; }
err() { printf 'Error: %s\n' "$*" >&2; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"
}

debug() {
  if [[ "$VERBOSE" -ge 1 ]]; then
    printf '[debug] %s\n' "$*" >&2
  fi
}

init_config() {
  local config_parent="."
  if [[ "$CONFIG_FILE" == */* ]]; then
    config_parent="${CONFIG_FILE%/*}"
  fi
  if [[ ! -d "$config_parent" ]]; then
    (umask 077; mkdir -p -- "$config_parent")
  fi
  (umask 077; touch "$CONFIG_FILE")
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true
}

require_value() {
  local option="$1"
  local count="$2"
  [[ "$count" -ge 2 ]] || die "$option requires a value"
}

require_exact_args() {
  local expected="$1"
  local usage_text="$2"
  local actual="$3"
  [[ "$actual" -eq "$expected" ]] || die "Usage: $0 $usage_text"
}

# Token precedence:
# 1) --token
# 2) GOFILE_TOKEN env
# 3) config file API_TOKEN=
get_token() {
  if [[ "$NO_AUTH" -eq 1 ]]; then
    printf '\n'
    return 0
  fi

  if [[ -n "${CLI_TOKEN:-}" ]]; then
    printf '%s\n' "$CLI_TOKEN"
    return 0
  fi

  if [[ -n "${GOFILE_TOKEN:-}" ]]; then
    printf '%s\n' "$GOFILE_TOKEN"
    return 0
  fi

  if [[ -f "$CONFIG_FILE" ]]; then
    awk '/^API_TOKEN=/{sub(/^API_TOKEN=/,""); sub(/\r$/, ""); print; exit}' "$CONFIG_FILE"
  else
    printf '\n'
  fi
}

require_token() {
  local t
  t="$(get_token)"
  [[ -n "$t" ]] || die "API token is not set. Use: $0 set-token <TOKEN>  (or export GOFILE_TOKEN=...)"
}

set_token() {
  local new_token="$1"
  [[ -n "$new_token" ]] || die "Usage: $0 set-token <TOKEN>"
  [[ "$new_token" != *$'\n'* && "$new_token" != *$'\r'* ]] || die "Token must be a single line"
  init_config

  local tmp
  tmp="$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")" || die "Could not create a temporary config file"
  trap '[[ -z "${tmp-}" ]] || rm -f -- "$tmp"' EXIT
  if [[ -s "$CONFIG_FILE" ]]; then
    grep -v '^API_TOKEN=' "$CONFIG_FILE" >"$tmp" || true
  fi
  printf 'API_TOKEN=%s\n' "$new_token" >>"$tmp"
  if ! mv -f "$tmp" "$CONFIG_FILE"; then
    rm -f -- "$tmp"
    die "Could not update $CONFIG_FILE"
  fi
  tmp=""
  trap - EXIT
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true
  say "API token saved to $CONFIG_FILE"
}

unset_token() {
  init_config
  local tmp
  tmp="$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")" || die "Could not create a temporary config file"
  trap '[[ -z "${tmp-}" ]] || rm -f -- "$tmp"' EXIT
  grep -v '^API_TOKEN=' "$CONFIG_FILE" >"$tmp" || true
  if ! mv -f "$tmp" "$CONFIG_FILE"; then
    rm -f -- "$tmp"
    die "Could not update $CONFIG_FILE"
  fi
  tmp=""
  trap - EXIT
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true
  say "API token removed from $CONFIG_FILE"
}

mask_token() {
  local t="$1"
  if [[ ${#t} -le 8 ]]; then
    printf '********'
  else
    printf '%s…%s' "${t:0:4}" "${t: -4}"
  fi
}

validate_password_hash() {
  local hash="$1"
  [[ "$hash" =~ ^[[:xdigit:]]{64}$ ]] || die "Password hash must be exactly 64 hexadecimal characters"
}

# resolve_password_hash <plain> <hash> -> prints the SHA-256 hex to send (or nothing)
resolve_password_hash() {
  local plain="$1"
  local hash="$2"
  [[ -z "$plain" || -z "$hash" ]] || die "Use either --password or --password-hash, not both"
  if [[ -n "$plain" ]]; then
    hash="$(sha256_hex "$plain")"
  fi
  [[ -z "$hash" ]] || validate_password_hash "$hash"
  printf '%s' "$hash"
}

is_uuid() {
  [[ "$1" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]
}

# The API resolves share codes only on read endpoints; everything that
# modifies content needs the UUID.
warn_if_not_uuid() {
  local label="$1"
  local value="$2"
  local id
  local -a id_list=()
  IFS=',' read -r -a id_list <<< "$value"
  for id in ${id_list[@]+"${id_list[@]}"}; do
    if ! is_uuid "$id"; then
      warn "$label '$id' is not a UUID. Share codes work only with get-content, ls and search-content; this request will likely be rejected."
    fi
  done
}

require_uint() {
  local label="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || die "$label must be a non-negative integer"
}

validate_http_settings() {
  [[ "$CURL_CONNECT_TIMEOUT" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "GOFILE_CONNECT_TIMEOUT must be a non-negative number"
  [[ "$CURL_MAX_TIME" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "GOFILE_MAX_TIME must be a non-negative number"
}

is_official_gofile_url() {
  [[ "$1" =~ ^https://([[:alnum:]-]+\.)*gofile\.io(/|$) ]]
}

curl_form_escape_path() {
  local path="$1"
  path="${path//\\/\\\\}"
  path="${path//\"/\\\"}"
  printf '%s' "$path"
}

print_json() {
  case "$OUTPUT_MODE" in
    raw) cat ;;
    compact) jq -c '.' ;;
    pretty|*) jq '.' ;;
  esac
}

# SHA-256 helper for password hashing (API expects sha256 hex for password query params)
sha256_hex() {
  local s="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$s" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$s" | shasum -a 256 | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    # openssl output differs across versions; -r is usually: "<hash> *stdin"
    local out
    out="$(printf '%s' "$s" | openssl dgst -sha256 -r 2>/dev/null || true)"
    if [[ -n "$out" ]]; then
      echo "$out" | awk '{print $1}'
    else
      # fallback: "(stdin)= <hash>"
      printf '%s' "$s" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}'
    fi
  else
    die "To hash passwords you need one of: sha256sum, shasum, openssl"
  fi
}

extract_id() {
  # Allow passing a gofile share URL; extract the code/ID.
  # e.g. https://gofile.io/d/AbCdEf  -> AbCdEf
  local input="$1"
  if [[ "$input" =~ ^https?:// ]]; then
    if [[ "$input" =~ /d/([A-Za-z0-9_-]+) ]]; then
      echo "${BASH_REMATCH[1]}"
      return 0
    fi
    if [[ "$input" =~ [\?\&]c=([A-Za-z0-9_-]+) ]]; then
      echo "${BASH_REMATCH[1]}"
      return 0
    fi
  fi
  echo "$input"
}

# --------------------------------------------------
# HTTP helpers (status-aware)
# --------------------------------------------------

api_error_hint() {
  case "$1" in
    error-token) err "Hint: the token is missing or was rejected (set-token / GOFILE_TOKEN / --token)." ;;
    error-accountId) err "Hint: the account ID does not belong to this token (see: get-account-id)." ;;
    error-notPremium) err "Hint: this endpoint requires a Gofile Premium account." ;;
    error-rateLimit) err "Hint: rate limit exceeded; wait before retrying." ;;
    error-limits) err "Hint: account quota exceeded (storage or content count)." ;;
    error-notFound) err "Hint: unknown content ID (mutations need the UUID, not a share code)." ;;
    error-owner|error-notOwner) err "Hint: the content belongs to another account." ;;
    error-rootFolder|error-protectedFolder) err "Hint: this operation is not allowed on the root folder." ;;
  esac
}

handle_response() {
  # handle_response URL RESPONSE   (RESPONSE = body + newline + HTTP code)
  local url="$1"
  local resp="$2"
  local http_code="${resp##*$'\n'}"
  local body="${resp%$'\n'*}"

  if [[ ! "$http_code" =~ ^[0-9]{3}$ ]]; then
    err "Invalid HTTP status from $url"
    return 1
  fi

  # The API wraps everything in {"status": ...}; always branch on it, since
  # some endpoints answer HTTP 200 with an error status.
  local status=""
  status="$(printf '%s\n' "$body" | jq -r 'if type == "object" then (.status // empty) else empty end' 2>/dev/null || true)"

  if (( 10#$http_code < 200 || 10#$http_code >= 300 )); then
    err "HTTP $http_code from $url${status:+ (API status=$status)}"
    api_error_hint "$status"
    printf '%s\n' "$body" >&2
    return 1
  fi

  if ! printf '%s\n' "$body" | jq -e '.' >/dev/null 2>&1; then
    err "Non-JSON response from $url"
    printf '%s\n' "$body" >&2
    return 1
  fi

  if [[ -n "$status" && "$status" != "ok" ]]; then
    err "API status=$status"
    api_error_hint "$status"
    printf '%s\n' "$body" >&2
    return 1
  fi

  printf '%s\n' "$body"
}

curl_json() {
  # curl_json METHOD URL [JSON_DATA]
  local method="$1"
  local url="$2"
  local data="${3-}"

  local token
  token="$(get_token)"

  local args=(
    -sS
    --connect-timeout "$CURL_CONNECT_TIMEOUT"
    --max-time "$CURL_MAX_TIME"
    -X "$method"
    -H "Accept: application/json"
    -H "User-Agent: gofile-cli/$VERSION"
  )
  if [[ -n "$token" ]]; then
    args+=(-H "Authorization: Bearer $token")
  fi

  if [[ -n "$data" ]]; then
    args+=(-H "Content-Type: application/json" -d "$data")
  fi

  debug "curl_json $method $url"

  local resp
  if ! resp="$(curl "${args[@]}" "$url" -w $'\n%{http_code}')"; then
    err "Request failed: $method $url"
    return 1
  fi
  handle_response "$url" "$resp"
}

curl_json_get_urlencoded() {
  # curl_json_get_urlencoded URL [key value ...]
  local url="$1"
  shift

  local token
  token="$(get_token)"

  local args=(
    -sS
    --connect-timeout "$CURL_CONNECT_TIMEOUT"
    --max-time "$CURL_MAX_TIME"
    -G
    -H "Accept: application/json"
    -H "User-Agent: gofile-cli/$VERSION"
  )
  if [[ -n "$token" ]]; then
    args+=(-H "Authorization: Bearer $token")
  fi

  while [[ $# -gt 0 ]]; do
    [[ $# -ge 2 ]] || die "Internal error: query parameter has no value"
    local k="$1"; local v="$2"
    args+=(--data-urlencode "$k=$v")
    shift 2
  done

  debug "curl_json_get_urlencoded $url"

  local resp
  if ! resp="$(curl "${args[@]}" "$url" -w $'\n%{http_code}')"; then
    err "Request failed: GET $url"
    return 1
  fi
  handle_response "$url" "$resp"
}

curl_upload() {
  # curl_upload URL FILE [folderId] [progress] [token]
  local url="$1"
  local file="$2"
  local folder_id="${3-}"
  local progress="${4-0}"
  local token="${5-}"   # explicit token (may be empty)

  [[ -f "$file" ]] || die "File not found: $file"

  local args=(
    --connect-timeout "$CURL_CONNECT_TIMEOUT"
    --max-time "$CURL_MAX_TIME"
    -X POST
    -H "Accept: application/json"
    -H "User-Agent: gofile-cli/$VERSION"
  )
  if [[ -n "$token" ]]; then
    args+=(-H "Authorization: Bearer $token")
  fi

  if [[ "$progress" -eq 1 ]]; then
    args+=(--progress-bar)
  else
    args+=(-sS)
  fi

  local escaped_file
  escaped_file="$(curl_form_escape_path "$file")"
  args+=(-F "file=@\"${escaped_file}\"")
  if [[ -n "$folder_id" ]]; then
    args+=(-F "folderId=$folder_id")
  fi

  debug "curl_upload $url file=$file folder=$folder_id auth=$([[ -n "$token" ]] && echo yes || echo no)"

  local resp
  if ! resp="$(curl "${args[@]}" "$url" -w $'\n%{http_code}')"; then
    err "Upload failed: $file"
    return 1
  fi
  handle_response "$url" "$resp"
}

# --------------------------------------------------
# Usage
# --------------------------------------------------

usage() {
  cat <<EOF
gofile.sh v$VERSION

Usage:
  $0 [global options] <command> [args...]

Global options:
  --token <TOKEN>     Use TOKEN for this invocation (overrides config/env)
  --guest             Do NOT send Authorization header (guest mode) for this invocation
  -v, --verbose       Verbose output (repeat for more)
  --raw               Print raw JSON (no jq formatting)
  --compact           Print compact JSON (jq -c)
  --version           Show version
  -h, --help          Show help

Token management:
  set-token <TOKEN>          Save token to ${CONFIG_FILE}
  show-token                 Show token (masked)
  unset-token                Remove token from config
  hash-password <PASSWORD>   Print sha256(password) hex (for --password-hash usage)

Server info:
  get-servers [zone]         Show storage servers (zone optional: eu|na).
                             Legacy endpoint, no longer part of the official API reference.

Upload:
  upload <file...> [--folder <folderId>] [--region <region>] [--zone eu|na] [--server <storeX>] [--url <uploadUrl>] [--allow-custom-auth] [--progress] [--json]
      - Default is official global upload endpoint: ${UPLOAD_URL_DEFAULT}
      - Regions: ${UPLOAD_REGIONS// /, }
      - --folder needs the folder UUID (share codes are not accepted for uploads).
      - --zone eu|na is a compatibility alias for eu-par|na-phx.
      - --server uses the legacy https://<server>.gofile.io/contents/uploadfile endpoint.
      - --allow-custom-auth explicitly permits sending your token to a non-Gofile --url.
      - If uploading multiple files without --folder, it will reuse the folder created/used by the first upload.

Content (IDs are UUIDs; get-content, ls and search-content also accept a share code or share URL):
  get-content <idOrCodeOrUrl> [read options]                     (Premium)
  ls <idOrCodeOrUrl> [read options] [--json]                     (Premium)
      read options:
        --password <plain> | --password-hash <sha256hex>
        --page <n> --page-size <n>
        --sort-field createTime|name|size|downloads|mimetype
        --sort-direction asc|desc
        --filter <text>          Substring filter on child names and tags
        --max-depth <1-16>       Nested children depth
  search-content <idOrCodeOrUrl> <query> [--password <plain>] [--password-hash <sha256hex>]
                 [--created-from <unix>] [--created-to <unix>]   (Premium)
  create-folder <parentFolderId> [name] [--public true|false]

  update-content <contentId> <attribute> <value> [--delete-after-expiry] [--no-hash]
      attributes: name, description, tags, public, password, expiry, modTime
      - An empty value ("") removes description, tags, password or expiry.
      - password is stored as sha256(value), matching what --password sends
        when reading; --no-hash sends the value unchanged.
      - --delete-after-expiry (expiry only) opts into permanent deletion at expiry.

  delete-content <contentIdsCsv>

Direct links (Premium):
  create-direct-link <contentId> [expireTime] [ipsCsv] [domainsAllowedCsv] [authCsv] [domainsBlockedCsv]
  update-direct-link <contentId> <directLinkId> [expireTime] [ipsCsv] [domainsAllowedCsv] [authCsv] [domainsBlockedCsv]
      - Pass "" to skip a field. On update, skipped fields keep their current
        value and "none" removes the restriction (or the expiry).
  delete-direct-link <contentId> <directLinkId>

Moves / copies (Premium):
  copy-content <contentsIdCsv> <destFolderId> [--password <plain>] [--password-hash <sha256hex>]
  move-content <contentsIdCsv> <destFolderId>
  import-content <contentsIdCsv> [--password <plain>] [--password-hash <sha256hex>]

Account:
  create-account [email]     Create a guest account (prints its token), or a
                             standard account when an email is given
  get-account-id
  get-account <accountId>
  whoami                 Prints account id + root folder id (if available)
  reset-token <accountId>

Examples:
  $0 set-token abc123
  $0 upload ./video.mp4 --progress
  $0 upload ./a.bin ./b.bin --json
  $0 ls https://gofile.io/d/AbCdEf --sort-field name --sort-direction asc
  $0 search-content <folderId> "music files"
  $0 create-folder <parentId> "My Folder" --public true
  $0 update-direct-link <contentId> <linkId> none "" "" none

EOF
}

# --------------------------------------------------
# Commands
# --------------------------------------------------

cmd_show_token() {
  if [[ "$NO_AUTH" -eq 1 ]]; then
    say "Authentication is disabled for this invocation (--guest)."
    return 0
  fi

  local t
  t="$(get_token)"
  if [[ -z "$t" ]]; then
    say "No API token set."
  else
    say "Token: $(mask_token "$t")"
    if [[ -n "$CLI_TOKEN" ]]; then
      say "Source: --token"
    elif [[ -n "${GOFILE_TOKEN:-}" ]]; then
      say "Source: GOFILE_TOKEN"
    else
      say "Source: $CONFIG_FILE"
    fi
  fi
}

cmd_get_servers() {
  # /servers is public (token not required), but we still include Authorization if available.
  [[ $# -le 1 ]] || die "Usage: $0 get-servers [zone]"
  local zone="${1-}"
  if [[ -n "$zone" ]]; then
    [[ "$zone" == "eu" || "$zone" == "na" ]] || die "zone must be eu or na"
    curl_json_get_urlencoded "${API_BASE}/servers" zone "$zone" | print_json
  else
    curl_json "GET" "${API_BASE}/servers" | print_json
  fi
}

cmd_upload() {
  # upload <file...> [--folder <folderId>] [--region <region>] [--zone eu|na]
  #        [--server storeX] [--url <uploadUrl>] [--progress] [--json]
  local folder_id=""
  local folder_was_set=0
  local region=""
  local zone=""
  local server=""
  local upload_url="$UPLOAD_URL_DEFAULT"
  local endpoint_options=0
  local allow_custom_auth=0
  local progress=0
  local as_json=0

  local -a args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --folder|-f)
        require_value "$1" "$#"
        folder_id="$2"
        folder_was_set=1
        shift 2
        ;;
      --region)
        require_value "$1" "$#"
        region="$2"
        endpoint_options=$((endpoint_options + 1))
        shift 2
        ;;
      --zone)
        require_value "$1" "$#"
        zone="$2"
        endpoint_options=$((endpoint_options + 1))
        shift 2
        ;;
      --server)
        require_value "$1" "$#"
        server="$2"
        endpoint_options=$((endpoint_options + 1))
        shift 2
        ;;
      --url)
        require_value "$1" "$#"
        upload_url="$2"
        endpoint_options=$((endpoint_options + 1))
        shift 2
        ;;
      --allow-custom-auth) allow_custom_auth=1; shift ;;
      --progress) progress=1; shift ;;
      --json) as_json=1; shift ;;
      --) shift; break ;;
      -h|--help) usage; exit 0 ;;
      -*) die "Unknown upload option: $1" ;;
      *) args+=("$1"); shift ;;
    esac
  done
  while [[ $# -gt 0 ]]; do args+=("$1"); shift; done

  [[ ${#args[@]} -gt 0 ]] || die "Usage: $0 upload <file...> [--folder <folderIdOrUrl>] [--region <region>] [--zone eu|na]"
  (( endpoint_options <= 1 )) || die "Use only one of --region, --zone, --server, or --url"

  if [[ "$folder_was_set" -eq 1 ]]; then
    [[ -n "$folder_id" ]] || die "--folder requires a non-empty folder ID"
    folder_id="$(extract_id "$folder_id")"
    warn_if_not_uuid "Folder ID" "$folder_id"
  fi

  if [[ -n "$region" ]]; then
    case "$region" in
      eu-par|na-phx|na-nyc|ap-sgp|ap-hkg|ap-tyo|ap-syd|sa-sao) ;;
      *) die "Unknown region: $region (expected one of: $UPLOAD_REGIONS)" ;;
    esac
    upload_url="https://upload-${region}.gofile.io/uploadfile"
  elif [[ -n "$zone" ]]; then
    case "$zone" in
      eu) upload_url="https://upload-eu-par.gofile.io/uploadfile" ;;
      na) upload_url="https://upload-na-phx.gofile.io/uploadfile" ;;
      *) die "zone must be eu or na" ;;
    esac
  elif [[ -n "$server" ]]; then
    [[ "$server" =~ ^[[:alnum:]-]+$ ]] || die "Invalid server name: $server"
    upload_url="https://${server}.gofile.io/contents/uploadfile"
  fi

  [[ "$upload_url" =~ ^https:// ]] || die "Upload URL must use HTTPS"

  local f
  for f in "${args[@]}"; do
    [[ -f "$f" ]] || die "File not found: $f"
    [[ -r "$f" ]] || die "File is not readable: $f"
  done

  local token
  token="$(get_token)"
  if [[ -n "$token" && "$allow_custom_auth" -eq 0 ]] && ! is_official_gofile_url "$upload_url"; then
    die "Refusing to send your token to a non-Gofile URL. Use --guest or explicitly pass --allow-custom-auth."
  fi

  local session_token="$token"
  local used_folder="$folder_id"
  local -a responses=()

  for f in "${args[@]}"; do
    local resp
    resp="$(curl_upload "$upload_url" "$f" "$used_folder" "$progress" "$session_token")"

    if [[ "$as_json" -eq 1 ]]; then
      responses+=("$resp")
    else
      local file_name download_page file_id
      file_name="$(printf '%s\n' "$resp" | jq -r '.data.name // .data.fileName // empty')"
      download_page="$(printf '%s\n' "$resp" | jq -r '.data.downloadPage // empty')"
      file_id="$(printf '%s\n' "$resp" | jq -r '.data.id // .data.fileId // empty')"
      [[ -n "$file_name" ]] || file_name="$(basename "$f")"
      say "✅ Uploaded: $file_name"
      [[ -n "$download_page" ]] && say "   🔗 $download_page"
      [[ -n "$file_id" ]] && say "   id: $file_id"
    fi

    if [[ -z "$folder_id" ]]; then
      local pf
      pf="$(printf '%s\n' "$resp" | jq -r '.data.parentFolder // .data.folderId // empty')"
      if [[ -n "$pf" ]]; then
        used_folder="$pf"
      fi
    fi

    if [[ -z "$token" ]]; then
      local gt
      gt="$(printf '%s\n' "$resp" | jq -r '.data.guestToken // .data.token // empty')"
      if [[ -n "$gt" ]]; then
        session_token="$gt"
      fi
    fi
  done

  if [[ "$as_json" -eq 1 ]]; then
    printf '%s\n' "${responses[@]}" | jq -s '.' | print_json
  fi
}

cmd_upload_file_compat() {
  # Backwards compatible with your original:
  # upload-file <filePath> [folderId] [zoneOrServer]
  [[ $# -le 3 ]] || die "Usage: $0 upload-file <filePath> [folderId] [zoneOrServer]"
  local filePath="${1-}"
  local folderId="${2-}"
  local zoneOrServer="${3-}"

  [[ -n "$filePath" ]] || die "Usage: $0 upload-file <filePath> [folderId] [zoneOrServer]"

  # Smart fix: allow "upload-file file eu" (zone w/out folder)
  if [[ -z "$zoneOrServer" && ( "$folderId" == "eu" || "$folderId" == "na" ) ]]; then
    zoneOrServer="$folderId"
    folderId=""
  fi

  local -a upload_args=("$filePath")
  if [[ -n "$folderId" ]]; then
    upload_args+=(--folder "$folderId")
  fi

  if [[ -n "$zoneOrServer" && ( "$zoneOrServer" == "eu" || "$zoneOrServer" == "na" ) ]]; then
    cmd_upload "${upload_args[@]}" --zone "$zoneOrServer" --json
  elif [[ -n "$zoneOrServer" ]]; then
    cmd_upload "${upload_args[@]}" --server "$zoneOrServer" --json
  else
    cmd_upload "${upload_args[@]}" --json
  fi
}

cmd_create_folder() {
  # create-folder <parentFolderId> [folderName] [--public true|false]
  local parent="${1-}"
  [[ -n "$parent" ]] || die "Usage: $0 create-folder <parentFolderId> [folderName] [--public true|false]"
  shift
  parent="$(extract_id "$parent")"

  local name=""
  local public_val=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --public)
        require_value "$1" "$#"
        public_val="$2"
        shift 2
        ;;
      --)
        shift
        while [[ $# -gt 0 ]]; do
          [[ -z "$name" ]] || die "Only one folder name may be specified"
          name="$1"
          shift
        done
        ;;
      -*) die "Unknown create-folder option: $1" ;;
      *)
        [[ -z "$name" ]] || die "Only one folder name may be specified"
        name="$1"
        shift
        ;;
    esac
  done

  if [[ -n "$public_val" && "$public_val" != "true" && "$public_val" != "false" ]]; then
    die "--public must be true or false"
  fi

  require_token
  warn_if_not_uuid "Parent folder ID" "$parent"

  local payload
  if [[ -n "$name" ]]; then
    payload="$(jq -n --arg pid "$parent" --arg fn "$name" '{ parentFolderId: $pid, folderName: $fn }')"
  else
    payload="$(jq -n --arg pid "$parent" '{ parentFolderId: $pid }')"
  fi

  if [[ -n "$public_val" ]]; then
    payload="$(printf '%s\n' "$payload" | jq --argjson p "$public_val" '. + {public: $p}')"
  fi

  curl_json "POST" "${API_BASE}/contents/createFolder" "$payload" | print_json
}

cmd_update_content() {
  # update-content <contentId> <attribute> <value> [--delete-after-expiry] [--no-hash]
  local usage_text="update-content <contentId> <attribute> <value> [--delete-after-expiry] [--no-hash]"
  local delete_after=0
  local no_hash=0
  local -a pos=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --delete-after-expiry) delete_after=1; shift ;;
      --no-hash) no_hash=1; shift ;;
      --)
        shift
        while [[ $# -gt 0 ]]; do pos+=("$1"); shift; done
        ;;
      *) pos+=("$1"); shift ;;
    esac
  done
  [[ ${#pos[@]} -eq 3 ]] || die "Usage: $0 $usage_text"

  local cid="${pos[0]}"
  local attr="${pos[1]}"
  local val="${pos[2]}"

  cid="$(extract_id "$cid")"
  [[ -n "$cid" ]] || die "Content ID must not be empty"
  [[ "$delete_after" -eq 0 || "$attr" == "expiry" ]] || die "--delete-after-expiry is only valid with the expiry attribute"
  [[ "$no_hash" -eq 0 || "$attr" == "password" ]] || die "--no-hash is only valid with the password attribute"

  local payload

  case "$attr" in
    name)
      [[ -n "$val" ]] || die "name must not be empty"
      [[ ${#val} -le 255 ]] || die "name must be at most 255 characters"
      payload="$(jq -n --arg a "$attr" --arg v "$val" '{attribute:$a, attributeValue:$v}')"
      ;;
    description)
      [[ ${#val} -le 2000 ]] || die "description must be at most 2000 characters"
      payload="$(jq -n --arg a "$attr" --arg v "$val" '{attribute:$a, attributeValue:$v}')"
      ;;
    tags)
      payload="$(jq -n --arg a "$attr" --arg v "$val" '{attribute:$a, attributeValue:$v}')"
      ;;
    public)
      if [[ "$val" == "true" || "$val" == "false" ]]; then
        payload="$(jq -n --arg a "$attr" --arg v "$val" '{attribute:$a, attributeValue:$v}')"
      else
        die "public must be true or false"
      fi
      ;;
    password)
      # Readers send sha256(password) as the "password" parameter, so the
      # stored value has to be that hash. An empty value removes the password.
      if [[ -n "$val" && "$no_hash" -eq 0 ]]; then
        [[ ${#val} -ge 4 && ${#val} -le 100 ]] || die "password must be 4-100 characters (empty removes it)"
        val="$(sha256_hex "$val")"
      fi
      payload="$(jq -n --arg a "$attr" --arg v "$val" '{attribute:$a, attributeValue:$v}')"
      ;;
    expiry)
      # Unix timestamp; an empty value removes the expiry.
      if [[ -z "$val" ]]; then
        payload="$(jq -n --arg a "$attr" '{attribute:$a, attributeValue:""}')"
      elif [[ "$val" =~ ^[0-9]+$ ]]; then
        payload="$(jq -n --arg a "$attr" --argjson v "$val" '{attribute:$a, attributeValue:$v}')"
      else
        die "expiry must be a unix timestamp integer (or empty to remove it)"
      fi
      if [[ "$delete_after" -eq 1 ]]; then
        [[ -n "$val" ]] || die "--delete-after-expiry needs an expiry timestamp"
        payload="$(printf '%s\n' "$payload" | jq '. + {deleteAfterExpiry: true}')"
      fi
      ;;
    modTime)
      [[ "$val" =~ ^[0-9]+$ ]] || die "modTime must be a unix timestamp integer"
      payload="$(jq -n --arg a "$attr" --argjson v "$val" '{attribute:$a, attributeValue:$v}')"
      ;;
    *) die "Unsupported attribute: $attr (expected name, description, tags, public, password, expiry, or modTime)" ;;
  esac

  require_token
  warn_if_not_uuid "Content ID" "$cid"
  curl_json "PUT" "${API_BASE}/contents/${cid}/update" "$payload" | print_json
}

cmd_delete_content() {
  require_exact_args 1 "delete-content <contentIdsCsv>" "$#"
  local ids="$1"
  [[ -n "$ids" ]] || die "Content IDs must not be empty"
  require_token
  warn_if_not_uuid "Content ID" "$ids"
  local payload
  payload="$(jq -n --arg cid "$ids" '{ contentsId: $cid }')"
  curl_json "DELETE" "${API_BASE}/contents" "$payload" | print_json
}

# Options shared by get-content and ls. Fills READ_QUERY with key/value pairs
# for GET /contents/{contentId} and sets READ_JSON / READ_SORTED.
READ_QUERY=()
READ_JSON=0
READ_SORTED=0
parse_read_options() {
  local cmd_name="$1"
  shift

  READ_QUERY=()
  READ_JSON=0
  READ_SORTED=0
  local pw_plain=""
  local pw_hash=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)
        [[ "$cmd_name" == "ls" ]] || die "Unknown $cmd_name option: $1"
        READ_JSON=1
        shift
        ;;
      --password)
        require_value "$1" "$#"
        pw_plain="$2"
        shift 2
        ;;
      --password-hash)
        require_value "$1" "$#"
        pw_hash="$2"
        shift 2
        ;;
      --page)
        require_value "$1" "$#"
        [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "--page must be a positive integer"
        READ_QUERY+=(page "$2")
        shift 2
        ;;
      --page-size)
        require_value "$1" "$#"
        [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "--page-size must be a positive integer"
        READ_QUERY+=(pageSize "$2")
        shift 2
        ;;
      --sort-field)
        require_value "$1" "$#"
        case "$2" in
          createTime|name|size|downloads|mimetype) ;;
          *) die "--sort-field must be createTime, name, size, downloads, or mimetype" ;;
        esac
        READ_QUERY+=(sortField "$2")
        READ_SORTED=1
        shift 2
        ;;
      --sort-direction)
        require_value "$1" "$#"
        case "$2" in
          1|asc) READ_QUERY+=(sortDirection 1) ;;
          -1|desc) READ_QUERY+=(sortDirection -1) ;;
          *) die "--sort-direction must be asc (1) or desc (-1)" ;;
        esac
        READ_SORTED=1
        shift 2
        ;;
      --filter)
        require_value "$1" "$#"
        READ_QUERY+=(contentFilter "$2")
        shift 2
        ;;
      --max-depth)
        require_value "$1" "$#"
        [[ "$2" =~ ^([1-9]|1[0-6])$ ]] || die "--max-depth must be between 1 and 16"
        READ_QUERY+=(maxdepth "$2")
        shift 2
        ;;
      *) die "Unknown $cmd_name option: $1" ;;
    esac
  done

  pw_hash="$(resolve_password_hash "$pw_plain" "$pw_hash")"
  if [[ -n "$pw_hash" ]]; then
    READ_QUERY+=(password "$pw_hash")
  fi
}

READ_OPTIONS_USAGE="[--password <plain>] [--password-hash <sha256hex>] [--page <n>] [--page-size <n>] [--sort-field <field>] [--sort-direction asc|desc] [--filter <text>] [--max-depth <1-16>]"

cmd_get_content() {
  # get-content <contentId> [read options]
  local cid="${1-}"
  [[ -n "$cid" ]] || die "Usage: $0 get-content <contentIdOrCodeOrUrl> $READ_OPTIONS_USAGE"
  cid="$(extract_id "$cid")"
  shift

  parse_read_options "get-content" "$@"

  require_token
  curl_json_get_urlencoded "${API_BASE}/contents/${cid}" ${READ_QUERY[@]+"${READ_QUERY[@]}"} | print_json
}

cmd_search_content() {
  # search-content <folderId> <query> [--password <plain>] [--password-hash <hash>]
  #                [--created-from <unix>] [--created-to <unix>]
  local folder="${1-}"
  local q="${2-}"
  [[ -n "$folder" && -n "$q" ]] || die "Usage: $0 search-content <folderIdOrCodeOrUrl> <query> [--password <plain>] [--password-hash <sha256hex>] [--created-from <unix>] [--created-to <unix>]"
  folder="$(extract_id "$folder")"
  shift 2

  local pw_plain=""
  local pw_hash=""
  local -a query=(contentId "$folder" searchedString "$q")

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --password)
        require_value "$1" "$#"
        pw_plain="$2"
        shift 2
        ;;
      --password-hash)
        require_value "$1" "$#"
        pw_hash="$2"
        shift 2
        ;;
      --created-from)
        require_value "$1" "$#"
        require_uint "--created-from" "$2"
        query+=(createTimeFrom "$2")
        shift 2
        ;;
      --created-to)
        require_value "$1" "$#"
        require_uint "--created-to" "$2"
        query+=(createTimeTo "$2")
        shift 2
        ;;
      *) die "Unknown search-content option: $1" ;;
    esac
  done

  pw_hash="$(resolve_password_hash "$pw_plain" "$pw_hash")"
  if [[ -n "$pw_hash" ]]; then
    query+=(password "$pw_hash")
  fi

  require_token
  curl_json_get_urlencoded "${API_BASE}/contents/search" "${query[@]}" | print_json
}

cmd_ls() {
  # ls <folderIdOrUrl> [read options] [--json]
  local folder="${1-}"
  [[ -n "$folder" ]] || die "Usage: $0 ls <folderIdOrCodeOrUrl> $READ_OPTIONS_USAGE [--json]"
  folder="$(extract_id "$folder")"
  shift

  parse_read_options "ls" "$@"

  local resp
  require_token
  resp="$(curl_json_get_urlencoded "${API_BASE}/contents/${folder}" ${READ_QUERY[@]+"${READ_QUERY[@]}"})"

  if [[ "$READ_JSON" -eq 1 ]]; then
    printf '%s\n' "$resp" | print_json
    return 0
  fi

  # Human-friendly listing. A folder returns .data.children as a map keyed by
  # UUID; a file returns only its own payload. Server-side ordering is kept
  # when a sort option was given.
  printf '%-6s  %-36s  %s\n' "TYPE" "ID" "NAME"
  printf '%-6s  %-36s  %s\n' "----" "--" "----"

  printf '%s\n' "$resp" | jq -r --argjson sorted "$READ_SORTED" '
    (if .data.type == "file" then [.data]
     else ((.data.children // {}) | to_entries | map(.value)) end)
    | (if $sorted == 1 then . else sort_by(.type, (.name // "")) end)
    | .[]
    | [.type, .id, .name]
    | @tsv
  ' | while IFS=$'\t' read -r t id name; do
        printf '%-6s  %-36s  %s\n' "$t" "$id" "$name"
      done

  local page_info
  page_info="$(printf '%s\n' "$resp" | jq -r '
    (.metadata // {}) as $m
    | if ($m.totalPages // 1) > 1
      then "Page \($m.page // 1) of \($m.totalPages) (\($m.totalCount // "?") items); use --page <n> to see more."
      else empty end
  ')"
  if [[ -n "$page_info" ]]; then
    say "$page_info"
  fi
}

# Direct links helpers
csv_to_json_array() {
  # prints a JSON array from a comma-separated string
  jq -cn --arg s "$1" '$s | split(",") | map(select(length > 0))'
}

build_direct_link_payload() {
  # build_direct_link_payload <create|update> <expireTime> <ipsCsv> <domainsAllowedCsv> <authCsv> <domainsBlockedCsv>
  #
  # An empty value leaves the field out of the request. On update the API uses
  # PATCH semantics (omitted fields keep their value), so "none" clears a
  # restriction: [] for lists, the never-expires sentinel for expireTime.
  local mode="$1"
  local expireTime="$2"
  local -a keys=(sourceIpsAllowed domainsAllowed auth domainsBlocked)
  local -a values=("$3" "$4" "$5" "$6")

  local payload="{}"

  if [[ "$expireTime" == "none" ]]; then
    if [[ "$mode" == "update" ]]; then
      expireTime="$DIRECT_LINK_NEVER_EXPIRES"
    else
      expireTime=""
    fi
  fi
  if [[ -n "$expireTime" ]]; then
    [[ "$expireTime" =~ ^[0-9]+$ ]] || die "expireTime must be a unix timestamp integer (or none)"
    payload="$(printf '%s\n' "$payload" | jq --argjson et "$expireTime" '. + {expireTime: $et}')"
  fi

  local i value array
  for i in 0 1 2 3; do
    value="${values[$i]}"
    [[ -n "$value" ]] || continue
    if [[ "$value" == "none" ]]; then
      [[ "$mode" == "update" ]] || continue
      array="[]"
    else
      array="$(csv_to_json_array "$value")"
    fi
    payload="$(printf '%s\n' "$payload" | jq --arg k "${keys[$i]}" --argjson a "$array" '. + {($k): $a}')"
  done

  printf '%s\n' "$payload"
}

cmd_create_direct_link() {
  # create-direct-link <contentId> [expireTime] [ipsCsv] [domainsAllowedCsv] [authCsv] [domainsBlockedCsv]
  local usage_text="create-direct-link <contentId> [expireTime] [ipsCsv] [domainsAllowedCsv] [authCsv] [domainsBlockedCsv]"
  [[ $# -le 6 ]] || die "Usage: $0 $usage_text"
  local cid="${1-}"; cid="$(extract_id "${cid:-}")"
  [[ -n "$cid" ]] || die "Usage: $0 $usage_text"

  local payload
  payload="$(build_direct_link_payload create "${2-}" "${3-}" "${4-}" "${5-}" "${6-}")"

  require_token
  warn_if_not_uuid "Content ID" "$cid"
  curl_json "POST" "${API_BASE}/contents/${cid}/directlinks" "$payload" | print_json
}

cmd_update_direct_link() {
  # update-direct-link <contentId> <directLinkId> [expireTime] [ipsCsv] [domainsAllowedCsv] [authCsv] [domainsBlockedCsv]
  local usage_text="update-direct-link <contentId> <directLinkId> [expireTime|none] [ipsCsv|none] [domainsAllowedCsv|none] [authCsv|none] [domainsBlockedCsv|none]"
  [[ $# -le 7 ]] || die "Usage: $0 $usage_text"
  local cid="${1-}"; cid="$(extract_id "${cid:-}")"
  local dlid="${2-}"
  [[ -n "$cid" && -n "$dlid" ]] || die "Usage: $0 $usage_text"

  local payload
  payload="$(build_direct_link_payload update "${3-}" "${4-}" "${5-}" "${6-}" "${7-}")"
  [[ "$payload" != "{}" ]] || die "Nothing to update. Usage: $0 $usage_text"

  require_token
  warn_if_not_uuid "Content ID" "$cid"
  curl_json "PUT" "${API_BASE}/contents/${cid}/directlinks/${dlid}" "$payload" | print_json
}

cmd_delete_direct_link() {
  require_exact_args 2 "delete-direct-link <contentId> <directLinkId>" "$#"
  local cid="${1-}"; cid="$(extract_id "${cid:-}")"
  local dlid="${2-}"
  [[ -n "$cid" && -n "$dlid" ]] || die "Usage: $0 delete-direct-link <contentId> <directLinkId>"
  require_token
  warn_if_not_uuid "Content ID" "$cid"
  curl_json "DELETE" "${API_BASE}/contents/${cid}/directlinks/${dlid}" | print_json
}

cmd_copy_content() {
  # copy-content <contentsIdCsv> <destFolderId> [--password ...] [--password-hash ...]
  local contents="${1-}"
  local dest="${2-}"
  [[ -n "$contents" && -n "$dest" ]] || die "Usage: $0 copy-content <contentsIdCsv> <destFolderId> [--password <plain>] [--password-hash <sha256hex>]"
  dest="$(extract_id "$dest")"
  shift 2

  local pw_plain=""
  local pw_hash=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --password)
        require_value "$1" "$#"
        pw_plain="$2"
        shift 2
        ;;
      --password-hash)
        require_value "$1" "$#"
        pw_hash="$2"
        shift 2
        ;;
      *) die "Unknown copy-content option: $1" ;;
    esac
  done
  pw_hash="$(resolve_password_hash "$pw_plain" "$pw_hash")"

  local payload
  payload="$(jq -n --arg cid "$contents" --arg fid "$dest" '{ contentsId: $cid, folderId: $fid }')"
  if [[ -n "$pw_hash" ]]; then
    payload="$(printf '%s\n' "$payload" | jq --arg p "$pw_hash" '. + {password: $p}')"
  fi

  require_token
  warn_if_not_uuid "Content ID" "$contents"
  warn_if_not_uuid "Destination folder ID" "$dest"
  curl_json "POST" "${API_BASE}/contents/copy" "$payload" | print_json
}

cmd_move_content() {
  # move-content <contentsIdCsv> <destFolderId>
  require_exact_args 2 "move-content <contentsIdCsv> <destFolderId>" "$#"
  local contents="$1"
  local dest="$2"
  [[ -n "$contents" && -n "$dest" ]] || die "Content and destination IDs must not be empty"
  dest="$(extract_id "$dest")"

  local payload
  payload="$(jq -n --arg cid "$contents" --arg fid "$dest" '{ contentsId: $cid, folderId: $fid }')"

  require_token
  warn_if_not_uuid "Content ID" "$contents"
  warn_if_not_uuid "Destination folder ID" "$dest"
  curl_json "PUT" "${API_BASE}/contents/move" "$payload" | print_json
}

cmd_import_content() {
  # import-content <contentsIdCsv> [--password ...] [--password-hash ...]
  local contents="${1-}"
  [[ -n "$contents" ]] || die "Usage: $0 import-content <contentsIdCsv> [--password <plain>] [--password-hash <sha256hex>]"
  shift

  local pw_plain=""
  local pw_hash=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --password)
        require_value "$1" "$#"
        pw_plain="$2"
        shift 2
        ;;
      --password-hash)
        require_value "$1" "$#"
        pw_hash="$2"
        shift 2
        ;;
      *) die "Unknown import-content option: $1" ;;
    esac
  done
  pw_hash="$(resolve_password_hash "$pw_plain" "$pw_hash")"

  local payload
  payload="$(jq -n --arg cid "$contents" '{ contentsId: $cid }')"
  if [[ -n "$pw_hash" ]]; then
    payload="$(printf '%s\n' "$payload" | jq --arg p "$pw_hash" '. + {password: $p}')"
  fi

  require_token
  warn_if_not_uuid "Content ID" "$contents"
  curl_json "POST" "${API_BASE}/contents/import" "$payload" | print_json
}

cmd_create_account() {
  # create-account [email]
  # No token is needed (or sent): an empty body creates a guest account and
  # returns its token; with an email Gofile mails a sign-in link instead.
  [[ $# -le 1 ]] || die "Usage: $0 create-account [email]"
  local email="${1-}"
  local payload="{}"
  if [[ -n "$email" ]]; then
    [[ "$email" == *@* ]] || die "Invalid email address: $email"
    payload="$(jq -n --arg e "$email" '{ email: $e }')"
  fi
  NO_AUTH=1
  curl_json "POST" "${API_BASE}/accounts" "$payload" | print_json
}

cmd_get_account_id() {
  require_exact_args 0 "get-account-id" "$#"
  require_token
  curl_json "GET" "${API_BASE}/accounts/getid" | print_json
}

cmd_get_account() {
  require_exact_args 1 "get-account <accountId>" "$#"
  local id="$1"
  [[ -n "$id" ]] || die "Account ID must not be empty"
  require_token
  curl_json "GET" "${API_BASE}/accounts/${id}" | print_json
}

cmd_whoami() {
  require_exact_args 0 "whoami" "$#"
  require_token
  local resp_id
  resp_id="$(curl_json "GET" "${API_BASE}/accounts/getid")"
  local account_id
  account_id="$(printf '%s\n' "$resp_id" | jq -r '.data.id // empty')"
  [[ -n "$account_id" ]] || die "Could not determine account id"
  local resp_acct
  resp_acct="$(curl_json "GET" "${API_BASE}/accounts/${account_id}")"

  local root
  root="$(printf '%s\n' "$resp_acct" | jq -r '.data.rootFolder // empty')"

  say "Account: $account_id"
  if [[ -n "$root" ]]; then
    say "Root folder: $root"
  else
    say "Root folder: (not present in response)"
  fi
}

cmd_reset_token() {
  require_exact_args 1 "reset-token <accountId>" "$#"
  local id="$1"
  [[ -n "$id" ]] || die "Account ID must not be empty"
  require_token
  warn "The current token stops working immediately; the new one is emailed to the account address. Never reset a guest account token: it cannot be recovered."
  curl_json "POST" "${API_BASE}/accounts/${id}/resettoken" | print_json
}

cmd_hash_password() {
  require_exact_args 1 "hash-password <PASSWORD>" "$#"
  local pw="$1"
  [[ -n "$pw" ]] || die "Usage: $0 hash-password <PASSWORD>"
  sha256_hex "$pw"
}

# --------------------------------------------------
# Main
# --------------------------------------------------

main() {
  # Global option parsing
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --token)
        require_value "$1" "$#"
        CLI_TOKEN="$2"
        [[ -n "$CLI_TOKEN" ]] || die "--token requires a non-empty token"
        shift 2
        ;;
      --guest) NO_AUTH=1; shift ;;
      --raw) OUTPUT_MODE="raw"; shift ;;
      --compact) OUTPUT_MODE="compact"; shift ;;
      -v|--verbose) VERBOSE=$((VERBOSE+1)); shift ;;
      -h|--help) usage; exit 0 ;;
      --version) say "gofile.sh v$VERSION"; exit 0 ;;
      --) shift; break ;;
      -*) die "Unknown global option: $1" ;;
      *) break ;;
    esac
  done

  local cmd="${1-}"
  shift || true

  [[ "$NO_AUTH" -eq 0 || -z "$CLI_TOKEN" ]] || die "--guest and --token cannot be used together"

  case "$cmd" in
    get-servers|servers|upload|upload-file|create-folder|mkdir|update-content|delete-content|rm|get-content|search-content|search|ls|create-direct-link|update-direct-link|delete-direct-link|copy-content|move-content|import-content|create-account|get-account-id|get-account|whoami|reset-token)
      need_cmd curl
      need_cmd jq
      validate_http_settings
      ;;
  esac

  case "$cmd" in
    set-token)
      require_exact_args 1 "set-token <TOKEN>" "$#"
      set_token "$1"
      ;;
    show-token)
      require_exact_args 0 "show-token" "$#"
      cmd_show_token
      ;;
    unset-token)
      require_exact_args 0 "unset-token" "$#"
      unset_token
      ;;

    hash-password) cmd_hash_password "$@" ;;

    get-servers|servers) cmd_get_servers "$@" ;;

    upload) cmd_upload "$@" ;;
    upload-file) cmd_upload_file_compat "$@" ;;

    create-folder|mkdir) cmd_create_folder "$@" ;;
    update-content) cmd_update_content "$@" ;;
    delete-content|rm) cmd_delete_content "$@" ;;
    get-content) cmd_get_content "$@" ;;
    search-content|search) cmd_search_content "$@" ;;
    ls) cmd_ls "$@" ;;

    create-direct-link) cmd_create_direct_link "$@" ;;
    update-direct-link) cmd_update_direct_link "$@" ;;
    delete-direct-link) cmd_delete_direct_link "$@" ;;

    copy-content) cmd_copy_content "$@" ;;
    move-content) cmd_move_content "$@" ;;
    import-content) cmd_import_content "$@" ;;

    create-account) cmd_create_account "$@" ;;
    get-account-id) cmd_get_account_id "$@" ;;
    get-account) cmd_get_account "$@" ;;
    whoami) cmd_whoami "$@" ;;
    reset-token) cmd_reset_token "$@" ;;

    ""|help)
      require_exact_args 0 "help" "$#"
      usage
      ;;
    version)
      require_exact_args 0 "version" "$#"
      say "gofile.sh v$VERSION"
      ;;
    *) die "Unknown command: $cmd (run: $0 --help)" ;;
  esac
}

main "$@"
