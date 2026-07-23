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
#
# License: MIT (same spirit as original)
#

set -euo pipefail
IFS=$'\n\t'

VERSION="2.1.0"

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

OUTPUT_MODE="pretty"   # pretty|compact|raw
VERBOSE=0
CLI_TOKEN=""           # optional override via --token
NO_AUTH=0              # if 1, do not send Authorization even if token exists (guest mode)

# --------------------------------------------------
# Small helpers
# --------------------------------------------------

say() { printf '%s\n' "$*"; }
err() { printf 'Error: %s\n' "$*" >&2; }
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

  local resp http_code body
  if ! resp="$(curl "${args[@]}" "$url" -w $'\n%{http_code}')"; then
    err "Request failed: $method $url"
    return 1
  fi
  http_code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"

  if [[ ! "$http_code" =~ ^[0-9]{3}$ ]]; then
    err "Invalid HTTP status from $url"
    return 1
  fi

  if (( 10#$http_code < 200 || 10#$http_code >= 300 )); then
    err "HTTP $http_code from $url"
    printf '%s\n' "$body" >&2
    return 1
  fi

  # Validate JSON + API status
  if ! printf '%s\n' "$body" | jq -e '.' >/dev/null 2>&1; then
    err "Non-JSON response from $url"
    printf '%s\n' "$body" >&2
    return 1
  fi

  local status
  status="$(printf '%s\n' "$body" | jq -r '.status // empty')"
  if [[ -n "$status" && "$status" != "ok" ]]; then
    err "API status=$status"
    printf '%s\n' "$body" >&2
    return 1
  fi

  printf '%s\n' "$body"
}

curl_json_get_urlencoded() {
  # curl_json_get_urlencoded URL key value [key value ...]
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

  local resp http_code body
  if ! resp="$(curl "${args[@]}" "$url" -w $'\n%{http_code}')"; then
    err "Request failed: GET $url"
    return 1
  fi
  http_code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"

  if [[ ! "$http_code" =~ ^[0-9]{3}$ ]]; then
    err "Invalid HTTP status from $url"
    return 1
  fi

  if (( 10#$http_code < 200 || 10#$http_code >= 300 )); then
    err "HTTP $http_code from $url"
    printf '%s\n' "$body" >&2
    return 1
  fi

  if ! printf '%s\n' "$body" | jq -e '.' >/dev/null 2>&1; then
    err "Non-JSON response from $url"
    printf '%s\n' "$body" >&2
    return 1
  fi

  local status
  status="$(printf '%s\n' "$body" | jq -r '.status // empty')"
  if [[ -n "$status" && "$status" != "ok" ]]; then
    err "API status=$status"
    printf '%s\n' "$body" >&2
    return 1
  fi

  printf '%s\n' "$body"
}

curl_upload() {
  # curl_upload URL FILE [folderId]
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

  local resp http_code body
  if ! resp="$(curl "${args[@]}" "$url" -w $'\n%{http_code}')"; then
    err "Upload failed: $file"
    return 1
  fi
  http_code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"

  if [[ ! "$http_code" =~ ^[0-9]{3}$ ]]; then
    err "Invalid HTTP status from $url"
    return 1
  fi

  if (( 10#$http_code < 200 || 10#$http_code >= 300 )); then
    err "HTTP $http_code from $url"
    printf '%s\n' "$body" >&2
    return 1
  fi

  if ! printf '%s\n' "$body" | jq -e '.' >/dev/null 2>&1; then
    err "Non-JSON response from upload endpoint"
    printf '%s\n' "$body" >&2
    return 1
  fi

  local status
  status="$(printf '%s\n' "$body" | jq -r '.status // empty')"
  if [[ -n "$status" && "$status" != "ok" ]]; then
    err "API status=$status"
    printf '%s\n' "$body" >&2
    return 1
  fi

  printf '%s\n' "$body"
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
  get-servers [zone]         Show available servers (zone optional: eu|na)

Upload:
  upload <file...> [--folder <folderIdOrUrl>] [--region <region>] [--zone eu|na] [--server <storeX>] [--url <uploadUrl>] [--allow-custom-auth] [--progress] [--json]
      - Default is official global upload endpoint: ${UPLOAD_URL_DEFAULT}
      - Regions: eu-par, na-phx, ap-sgp, ap-hkg, ap-tyo, sa-sao
      - --zone eu|na is a compatibility alias for eu-par|na-phx.
      - --server uses the legacy https://<server>.gofile.io/contents/uploadfile endpoint.
      - --allow-custom-auth explicitly permits sending your token to a non-Gofile --url.
      - If uploading multiple files without --folder, it will reuse the folder created/used by the first upload.

Content:
  get-content <folderIdOrUrl> [--password <plain>] [--password-hash <sha256hex>]
  search-content <folderIdOrUrl> <query> [--password <plain>] [--password-hash <sha256hex>]
  ls <folderIdOrUrl> [--password <plain>] [--password-hash <sha256hex>] [--json]
                                               List children in a folder
  create-folder <parentFolderIdOrUrl> [name] [--public true|false]

  update-content <contentIdOrUrl> <attribute> <value>
      attributes: name, description, tags, public, expiry, password

  delete-content <contentIdsCsv>

Direct links:
  create-direct-link <contentIdOrUrl> [expireTime] [ipsCsv] [domainsAllowedCsv] [authCsv] [domainsBlockedCsv]
  update-direct-link <contentIdOrUrl> <directLinkId> [expireTime] [ipsCsv] [domainsAllowedCsv] [authCsv] [domainsBlockedCsv]
  delete-direct-link <contentIdOrUrl> <directLinkId>

Moves / copies:
  copy-content <contentsIdCsv> <destFolderIdOrUrl> [--password <plain>] [--password-hash <sha256hex>]
  move-content <contentsIdCsv> <destFolderIdOrUrl>
  import-content <contentsIdCsv> [--password <plain>] [--password-hash <sha256hex>]

Account:
  get-account-id
  get-account <accountId>
  whoami                 Prints account id + root folder id (if available)
  reset-token <accountId>

Examples:
  $0 set-token abc123
  $0 upload ./video.mp4 --progress
  $0 upload ./a.bin ./b.bin --json
  $0 get-servers eu
  $0 ls https://gofile.io/d/AbCdEf
  $0 search-content <folderId> "music files"
  $0 create-folder <parentId> "My Folder" --public true

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
  fi

  if [[ -n "$region" ]]; then
    case "$region" in
      eu-par|na-phx|ap-sgp|ap-hkg|ap-tyo|sa-sao) ;;
      *) die "Unknown region: $region (expected eu-par, na-phx, ap-sgp, ap-hkg, ap-tyo, or sa-sao)" ;;
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
      file_name="$(printf '%s\n' "$resp" | jq -r '.data.fileName // .data.name // empty')"
      download_page="$(printf '%s\n' "$resp" | jq -r '.data.downloadPage // empty')"
      file_id="$(printf '%s\n' "$resp" | jq -r '.data.fileId // empty')"
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
  # update-content <contentId> <attribute> <value>
  require_exact_args 3 "update-content <contentId> <attribute> <value>" "$#"

  local cid="$1"
  local attr="$2"
  local val="$3"

  cid="$(extract_id "$cid")"
  [[ -n "$cid" ]] || die "Content ID must not be empty"
  case "$attr" in
    name|description|tags|public|expiry|password) ;;
    *) die "Unsupported attribute: $attr (expected name, description, tags, public, expiry, or password)" ;;
  esac

  local payload

  case "$attr" in
    expiry)
      # numeric unix timestamp
      if [[ "$val" =~ ^[0-9]+$ ]]; then
        payload="$(jq -n --arg a "$attr" --argjson v "$val" '{attribute:$a, attributeValue:$v}')"
      else
        die "expiry must be a unix timestamp integer"
      fi
      ;;
    public)
      # API expects booleans as string "true"/"false" for update-content in many clients
      if [[ "$val" == "true" || "$val" == "false" ]]; then
        payload="$(jq -n --arg a "$attr" --arg v "$val" '{attribute:$a, attributeValue:$v}')"
      else
        die "public must be true or false"
      fi
      ;;
    *)
      payload="$(jq -n --arg a "$attr" --arg v "$val" '{attribute:$a, attributeValue:$v}')"
      ;;
  esac

  require_token
  curl_json "PUT" "${API_BASE}/contents/${cid}/update" "$payload" | print_json
}

cmd_delete_content() {
  require_exact_args 1 "delete-content <contentIdsCsv>" "$#"
  local ids="$1"
  [[ -n "$ids" ]] || die "Content IDs must not be empty"
  require_token
  local payload
  payload="$(jq -n --arg cid "$ids" '{ contentsId: $cid }')"
  curl_json "DELETE" "${API_BASE}/contents" "$payload" | print_json
}

cmd_get_content() {
  # get-content <contentId> [--password <plain>] [--password-hash <hash>]
  local cid="${1-}"
  [[ -n "$cid" ]] || die "Usage: $0 get-content <contentIdOrUrl> [--password <plain>] [--password-hash <sha256hex>]"
  cid="$(extract_id "$cid")"
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
      *) die "Unknown get-content option: $1" ;;
    esac
  done

  [[ -z "$pw_plain" || -z "$pw_hash" ]] || die "Use either --password or --password-hash, not both"
  if [[ -n "$pw_plain" && -z "$pw_hash" ]]; then
    pw_hash="$(sha256_hex "$pw_plain")"
  fi
  [[ -z "$pw_hash" ]] || validate_password_hash "$pw_hash"

  require_token
  if [[ -n "$pw_hash" ]]; then
    curl_json_get_urlencoded "${API_BASE}/contents/${cid}" password "$pw_hash" | print_json
  else
    curl_json "GET" "${API_BASE}/contents/${cid}" | print_json
  fi
}

cmd_search_content() {
  # search-content <folderId> <query> [--password <plain>] [--password-hash <hash>]
  local folder="${1-}"
  local q="${2-}"
  [[ -n "$folder" && -n "$q" ]] || die "Usage: $0 search-content <folderIdOrUrl> <query> [--password <plain>] [--password-hash <sha256hex>]"
  folder="$(extract_id "$folder")"
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
      *) die "Unknown search-content option: $1" ;;
    esac
  done

  [[ -z "$pw_plain" || -z "$pw_hash" ]] || die "Use either --password or --password-hash, not both"
  if [[ -n "$pw_plain" && -z "$pw_hash" ]]; then
    pw_hash="$(sha256_hex "$pw_plain")"
  fi
  [[ -z "$pw_hash" ]] || validate_password_hash "$pw_hash"

  require_token
  if [[ -n "$pw_hash" ]]; then
    curl_json_get_urlencoded "${API_BASE}/contents/search" contentId "$folder" searchedString "$q" password "$pw_hash" | print_json
  else
    curl_json_get_urlencoded "${API_BASE}/contents/search" contentId "$folder" searchedString "$q" | print_json
  fi
}

cmd_ls() {
  # ls <folderIdOrUrl> [--password <plain>] [--password-hash <hash>] [--json]
  local folder="${1-}"
  [[ -n "$folder" ]] || die "Usage: $0 ls <folderIdOrUrl> [--password <plain>] [--password-hash <sha256hex>] [--json]"
  folder="$(extract_id "$folder")"
  shift

  local as_json=0
  local pw_plain=""
  local pw_hash=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) as_json=1; shift ;;
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
      *) die "Unknown ls option: $1" ;;
    esac
  done

  [[ -z "$pw_plain" || -z "$pw_hash" ]] || die "Use either --password or --password-hash, not both"
  if [[ -n "$pw_plain" ]]; then
    pw_hash="$(sha256_hex "$pw_plain")"
  fi
  [[ -z "$pw_hash" ]] || validate_password_hash "$pw_hash"

  local resp
  require_token
  if [[ -n "$pw_hash" ]]; then
    resp="$(curl_json_get_urlencoded "${API_BASE}/contents/${folder}" password "$pw_hash")"
  else
    resp="$(curl_json "GET" "${API_BASE}/contents/${folder}")"
  fi

  if [[ "$as_json" -eq 1 ]]; then
    printf '%s\n' "$resp" | print_json
    return 0
  fi

  # Human-friendly listing (best-effort: works when API returns .data.children as a map)
  printf '%-6s  %-28s  %s\n' "TYPE" "ID" "NAME"
  printf '%-6s  %-28s  %s\n' "----" "--" "----"

  echo "$resp" | jq -r '
    (.data.children // {}) 
    | to_entries
    | sort_by(.value.type, (.value.name // "")) 
    | .[]
    | .value
    | [.type, .id, .name] 
    | @tsv
  ' | while IFS=$'\t' read -r t id name; do
        printf '%-6s  %-28s  %s\n' "$t" "$id" "$name"
      done
}

# Direct links helpers
csv_to_json_array() {
  # prints JSON array from comma-separated string
  local csv="$1"
  local -a arr=()
  IFS=',' read -r -a arr <<< "$csv"
  printf '%s\n' "${arr[@]}" | jq -R . | jq -s '.'
}

cmd_create_direct_link() {
  # create-direct-link <contentId> [expireTime] [ipsCsv] [domainsAllowedCsv] [authCsv] [domainsBlockedCsv]
  [[ $# -le 6 ]] || die "Usage: $0 create-direct-link <contentId> [expireTime] [ipsCsv] [domainsAllowedCsv] [authCsv] [domainsBlockedCsv]"
  local cid="${1-}"; cid="$(extract_id "${cid:-}")"
  [[ -n "$cid" ]] || die "Usage: $0 create-direct-link <contentId> [expireTime] [ipsCsv] [domainsAllowedCsv] [authCsv] [domainsBlockedCsv]"
  local expireTime="${2-}"
  local sourceIpsAllowed="${3-}"
  local domainsAllowed="${4-}"
  local auth="${5-}"
  local domainsBlocked="${6-}"

  local payload="{}"

  if [[ -n "$expireTime" ]]; then
    [[ "$expireTime" =~ ^[0-9]+$ ]] || die "expireTime must be a unix timestamp integer"
    payload="$(echo "$payload" | jq --arg et "$expireTime" '. + {expireTime: ($et|tonumber)}')"
  fi

  if [[ -n "$sourceIpsAllowed" ]]; then
    payload="$(echo "$payload" | jq --argjson a "$(csv_to_json_array "$sourceIpsAllowed")" '. + {sourceIpsAllowed: $a}')"
  fi

  if [[ -n "$domainsAllowed" ]]; then
    payload="$(echo "$payload" | jq --argjson a "$(csv_to_json_array "$domainsAllowed")" '. + {domainsAllowed: $a}')"
  fi

  if [[ -n "$domainsBlocked" ]]; then
    payload="$(echo "$payload" | jq --argjson a "$(csv_to_json_array "$domainsBlocked")" '. + {domainsBlocked: $a}')"
  fi

  if [[ -n "$auth" ]]; then
    payload="$(echo "$payload" | jq --argjson a "$(csv_to_json_array "$auth")" '. + {auth: $a}')"
  fi

  require_token
  curl_json "POST" "${API_BASE}/contents/${cid}/directlinks" "$payload" | print_json
}

cmd_update_direct_link() {
  # update-direct-link <contentId> <directLinkId> [expireTime] [ipsCsv] [domainsAllowedCsv] [authCsv] [domainsBlockedCsv]
  [[ $# -le 7 ]] || die "Usage: $0 update-direct-link <contentId> <directLinkId> [expireTime] [ipsCsv] [domainsAllowedCsv] [authCsv] [domainsBlockedCsv]"
  local cid="${1-}"; cid="$(extract_id "${cid:-}")"
  local dlid="${2-}"
  [[ -n "$cid" && -n "$dlid" ]] || die "Usage: $0 update-direct-link <contentId> <directLinkId> [expireTime] [ipsCsv] [domainsAllowedCsv] [authCsv] [domainsBlockedCsv]"
  local expireTime="${3-}"
  local sourceIpsAllowed="${4-}"
  local domainsAllowed="${5-}"
  local auth="${6-}"
  local domainsBlocked="${7-}"

  local payload="{}"

  if [[ -n "$expireTime" ]]; then
    [[ "$expireTime" =~ ^[0-9]+$ ]] || die "expireTime must be a unix timestamp integer"
    payload="$(echo "$payload" | jq --arg et "$expireTime" '. + {expireTime: ($et|tonumber)}')"
  fi

  if [[ -n "$sourceIpsAllowed" ]]; then
    payload="$(echo "$payload" | jq --argjson a "$(csv_to_json_array "$sourceIpsAllowed")" '. + {sourceIpsAllowed: $a}')"
  fi

  if [[ -n "$domainsAllowed" ]]; then
    payload="$(echo "$payload" | jq --argjson a "$(csv_to_json_array "$domainsAllowed")" '. + {domainsAllowed: $a}')"
  fi

  if [[ -n "$domainsBlocked" ]]; then
    payload="$(echo "$payload" | jq --argjson a "$(csv_to_json_array "$domainsBlocked")" '. + {domainsBlocked: $a}')"
  fi

  if [[ -n "$auth" ]]; then
    payload="$(echo "$payload" | jq --argjson a "$(csv_to_json_array "$auth")" '. + {auth: $a}')"
  fi

  require_token
  curl_json "PUT" "${API_BASE}/contents/${cid}/directlinks/${dlid}" "$payload" | print_json
}

cmd_delete_direct_link() {
  require_exact_args 2 "delete-direct-link <contentId> <directLinkId>" "$#"
  local cid="${1-}"; cid="$(extract_id "${cid:-}")"
  local dlid="${2-}"
  [[ -n "$cid" && -n "$dlid" ]] || die "Usage: $0 delete-direct-link <contentId> <directLinkId>"
  require_token
  curl_json "DELETE" "${API_BASE}/contents/${cid}/directlinks/${dlid}" | print_json
}

cmd_copy_content() {
  # copy-content <contentsIdCsv> <destFolderId> [--password ...] [--password-hash ...]
  local contents="${1-}"
  local dest="${2-}"
  [[ -n "$contents" && -n "$dest" ]] || die "Usage: $0 copy-content <contentsIdCsv> <destFolderIdOrUrl> [--password <plain>] [--password-hash <sha256hex>]"
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
  [[ -z "$pw_plain" || -z "$pw_hash" ]] || die "Use either --password or --password-hash, not both"
  if [[ -n "$pw_plain" ]]; then
    pw_hash="$(sha256_hex "$pw_plain")"
  fi
  [[ -z "$pw_hash" ]] || validate_password_hash "$pw_hash"

  local payload
  payload="$(jq -n --arg cid "$contents" --arg fid "$dest" '{ contentsId: $cid, folderId: $fid }')"
  if [[ -n "$pw_hash" ]]; then
    payload="$(printf '%s\n' "$payload" | jq --arg p "$pw_hash" '. + {password: $p}')"
  fi

  require_token
  curl_json "POST" "${API_BASE}/contents/copy" "$payload" | print_json
}

cmd_move_content() {
  # move-content <contentsIdCsv> <destFolderId>
  require_exact_args 2 "move-content <contentsIdCsv> <destFolderIdOrUrl>" "$#"
  local contents="$1"
  local dest="$2"
  [[ -n "$contents" && -n "$dest" ]] || die "Content and destination IDs must not be empty"
  dest="$(extract_id "$dest")"

  local payload
  payload="$(jq -n --arg cid "$contents" --arg fid "$dest" '{ contentsId: $cid, folderId: $fid }')"

  require_token
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
  [[ -z "$pw_plain" || -z "$pw_hash" ]] || die "Use either --password or --password-hash, not both"
  if [[ -n "$pw_plain" ]]; then
    pw_hash="$(sha256_hex "$pw_plain")"
  fi
  [[ -z "$pw_hash" ]] || validate_password_hash "$pw_hash"

  local payload
  payload="$(jq -n --arg cid "$contents" '{ contentsId: $cid }')"
  if [[ -n "$pw_hash" ]]; then
    payload="$(printf '%s\n' "$payload" | jq --arg p "$pw_hash" '. + {password: $p}')"
  fi

  require_token
  curl_json "POST" "${API_BASE}/contents/import" "$payload" | print_json
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
    get-servers|servers|upload|upload-file|create-folder|mkdir|update-content|delete-content|rm|get-content|search-content|search|ls|create-direct-link|update-direct-link|delete-direct-link|copy-content|move-content|import-content|get-account-id|get-account|whoami|reset-token)
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
