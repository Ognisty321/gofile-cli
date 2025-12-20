#!/usr/bin/env bash
#
# gofile.sh - A more robust Bash CLI for the Gofile.io API
#
# Requires: bash, curl, jq
#
# Notes:
# - Defaults to the official global upload endpoint:
#     POST https://upload.gofile.io/uploadfile  (Method Not Allowed on GET, so it exists)
# - Falls back to legacy store-server upload if you pass --server or --zone.
#
# License: MIT (same spirit as original)
#

set -euo pipefail
IFS=$'\n\t'

VERSION="2.0.0"

# --------------------------------------------------
# Config (XDG-friendly)
# --------------------------------------------------

XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
CONFIG_DIR="${GOFILE_CONFIG_DIR:-$XDG_CONFIG_HOME/gofile-cli}"
CONFIG_FILE="${GOFILE_CONFIG_FILE:-$CONFIG_DIR/config}"

API_BASE="${GOFILE_API_BASE:-https://api.gofile.io}"
UPLOAD_URL_DEFAULT="${GOFILE_UPLOAD_URL:-https://upload.gofile.io/uploadfile}"

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
  mkdir -p "$CONFIG_DIR"
  touch "$CONFIG_FILE"
  # best-effort permissions hardening
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true
}

# Token precedence:
# 1) --token
# 2) GOFILE_TOKEN env
# 3) config file API_TOKEN=
get_token() {
  if [[ "$NO_AUTH" -eq 1 ]]; then
    echo ""
    return 0
  fi

  if [[ -n "${CLI_TOKEN:-}" ]]; then
    echo "$CLI_TOKEN"
    return 0
  fi

  if [[ -n "${GOFILE_TOKEN:-}" ]]; then
    echo "$GOFILE_TOKEN"
    return 0
  fi

  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC2002
    cat "$CONFIG_FILE" | awk -F'=' '/^API_TOKEN=/{sub(/^API_TOKEN=/,""); print; exit}'
  else
    echo ""
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
  init_config

  # write atomically; keep any other lines
  local tmp
  tmp="$(mktemp)"
  if [[ -s "$CONFIG_FILE" ]]; then
    grep -v '^API_TOKEN=' "$CONFIG_FILE" >"$tmp" || true
  fi
  printf 'API_TOKEN=%s\n' "$new_token" >>"$tmp"
  mv "$tmp" "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true
  say "API token saved to $CONFIG_FILE"
}

unset_token() {
  init_config
  local tmp
  tmp="$(mktemp)"
  grep -v '^API_TOKEN=' "$CONFIG_FILE" >"$tmp" || true
  mv "$tmp" "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true
  say "API token removed from $CONFIG_FILE"
}

mask_token() {
  local t="$1"
  if [[ ${#t} -le 8 ]]; then
    printf '%s' "$t"
  else
    printf '%s…%s' "${t:0:4}" "${t: -4}"
  fi
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

  local args=(-sS -X "$method" -H "Accept: application/json")
  if [[ -n "$token" ]]; then
    args+=(-H "Authorization: Bearer $token")
  fi

  if [[ -n "$data" ]]; then
    args+=(-H "Content-Type: application/json" -d "$data")
  fi

  debug "curl_json $method $url"

  local resp http_code body
  resp="$(curl "${args[@]}" "$url" -w $'\n%{http_code}')"
  http_code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    err "HTTP $http_code from $url"
    printf '%s\n' "$body" >&2
    return 1
  fi

  # Validate JSON + API status
  if ! echo "$body" | jq -e '.' >/dev/null 2>&1; then
    err "Non-JSON response from $url"
    printf '%s\n' "$body" >&2
    return 1
  fi

  local status
  status="$(echo "$body" | jq -r '.status // empty')"
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

  local args=(-sS -G -H "Accept: application/json")
  if [[ -n "$token" ]]; then
    args+=(-H "Authorization: Bearer $token")
  fi

  while [[ $# -gt 0 ]]; do
    local k="$1"; local v="$2"
    args+=(--data-urlencode "$k=$v")
    shift 2
  done

  debug "curl_json_get_urlencoded $url"

  local resp http_code body
  resp="$(curl "${args[@]}" "$url" -w $'\n%{http_code}')"
  http_code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    err "HTTP $http_code from $url"
    printf '%s\n' "$body" >&2
    return 1
  fi

  if ! echo "$body" | jq -e '.' >/dev/null 2>&1; then
    err "Non-JSON response from $url"
    printf '%s\n' "$body" >&2
    return 1
  fi

  local status
  status="$(echo "$body" | jq -r '.status // empty')"
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
  local token="$5"   # explicit token (may be empty)

  [[ -f "$file" ]] || die "File not found: $file"

  local args=(-X POST -H "Accept: application/json")
  if [[ -n "$token" ]]; then
    args+=(-H "Authorization: Bearer $token")
  fi

  if [[ "$progress" -eq 1 ]]; then
    args+=(--progress-bar)
  else
    args+=(-sS)
  fi

  args+=(-F "file=@$file")
  if [[ -n "$folder_id" ]]; then
    args+=(-F "folderId=$folder_id")
  fi

  debug "curl_upload $url file=$file folder=$folder_id auth=$([[ -n "$token" ]] && echo yes || echo no)"

  local resp http_code body
  resp="$(curl "${args[@]}" "$url" -w $'\n%{http_code}')"
  http_code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    err "HTTP $http_code from $url"
    printf '%s\n' "$body" >&2
    return 1
  fi

  if ! echo "$body" | jq -e '.' >/dev/null 2>&1; then
    err "Non-JSON response from upload endpoint"
    printf '%s\n' "$body" >&2
    return 1
  fi

  local status
  status="$(echo "$body" | jq -r '.status // empty')"
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
  -h, --help          Show help

Token management:
  set-token <TOKEN>          Save token to ${CONFIG_FILE}
  show-token                 Show token (masked)
  unset-token                Remove token from config
  hash-password <PASSWORD>   Print sha256(password) hex (for --password-hash usage)

Server info:
  get-servers [zone]         Show available servers (zone optional: eu|na)

Upload:
  upload <file...> [--folder <folderId>] [--zone eu|na] [--server <storeX>] [--url <uploadUrl>] [--progress] [--json]
      - Default is official global upload endpoint: ${UPLOAD_URL_DEFAULT}
      - If you pass --zone or --server, it will upload to https://<server>.gofile.io/contents/uploadfile
      - If uploading multiple files without --folder, it will reuse the folder created/used by the first upload.

Content:
  get-content <folderIdOrUrl> [--password <plain>] [--password-hash <sha256hex>]
  search-content <folderIdOrUrl> <query> [--password <plain>] [--password-hash <sha256hex>]
  ls <folderIdOrUrl>                         List children in a folder (human-friendly)
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
  move-content <contentsIdCsv> <destFolderIdOrUrl> [--password <plain>] [--password-hash <sha256hex>]
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
  local t
  t="$(get_token)"
  if [[ -z "$t" ]]; then
    say "No API token set."
  else
    say "Token: $(mask_token "$t")"
    say "Config: $CONFIG_FILE"
  fi
}

cmd_get_servers() {
  # /servers is public (token not required), but we still include Authorization if available.
  local zone="${1-}"
  local url="${API_BASE}/servers"
  if [[ -n "$zone" ]]; then
    url="${url}?zone=${zone}"
  fi

  curl_json "GET" "$url" | print_json
}

pick_server_by_zone() {
  # outputs server name or empty
  local zone="$1"
  local resp
  resp="$(curl_json "GET" "${API_BASE}/servers?zone=${zone}")"
  echo "$resp" | jq -r '.data.servers[0].name // empty'
}

cmd_upload() {
  # upload <file...> [--folder <folderId>] [--zone eu|na] [--server storeX] [--url <uploadUrl>] [--progress] [--json]
  local folder_id=""
  local zone=""
  local server=""
  local upload_url="$UPLOAD_URL_DEFAULT"
  local progress=0
  local as_json=0

  # parse options (allow them anywhere before files)
  local args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --folder|-f) folder_id="${2-}"; shift 2 ;;
      --zone) zone="${2-}"; shift 2 ;;
      --server) server="${2-}"; shift 2 ;;
      --url) upload_url="${2-}"; shift 2 ;;
      --progress) progress=1; shift ;;
      --json) as_json=1; shift ;;
      --) shift; break ;;
      -h|--help) usage; exit 0 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  # any remaining positional args after --
  while [[ $# -gt 0 ]]; do args+=("$1"); shift; done

  [[ ${#args[@]} -gt 0 ]] || die "Usage: $0 upload <file...> [--folder <folderId>] [--zone eu|na] [--server <storeX>] [--url <uploadUrl>]"

  # Determine upload endpoint:
  # If --server explicitly set -> legacy store endpoint.
  # Else if --zone set -> pick a server and use legacy store endpoint.
  if [[ -n "$server" ]]; then
    upload_url="https://${server}.gofile.io/contents/uploadfile"
  elif [[ -n "$zone" ]]; then
    local picked
    picked="$(pick_server_by_zone "$zone")"
    [[ -n "$picked" ]] || die "No server found for zone=$zone"
    upload_url="https://${picked}.gofile.io/contents/uploadfile"
    server="$picked"
  fi

  local token
  token="$(get_token)"  # may be empty in guest mode
  local session_token="$token"

  local used_folder="$folder_id"

  # Collect JSON responses if requested
  local tmp_json
  tmp_json="$(mktemp)"
  : >"$tmp_json"

  for f in "${args[@]}"; do
    # If user provided a folderId, always reuse it.
    # Else if multiple uploads: after first upload, reuse returned parentFolder.
    local resp
    resp="$(curl_upload "$upload_url" "$f" "$used_folder" "$progress" "$session_token")"

    if [[ "$as_json" -eq 1 ]]; then
      printf '%s\n' "$resp" >>"$tmp_json"
    else
      local file_name download_page file_id parent_folder
      file_name="$(echo "$resp" | jq -r '.data.fileName // .data.name // empty')"
      download_page="$(echo "$resp" | jq -r '.data.downloadPage // empty')"
      file_id="$(echo "$resp" | jq -r '.data.fileId // empty')"
      parent_folder="$(echo "$resp" | jq -r '.data.parentFolder // .data.folderId // empty')"
      [[ -n "$file_name" ]] || file_name="$(basename "$f")"
      say "✅ Uploaded: $file_name"
      [[ -n "$download_page" ]] && say "   🔗 $download_page"
      [[ -n "$file_id" ]] && say "   id: $file_id"
    fi

    # Smart reuse: if no folder was specified, reuse the folder returned by first upload
    if [[ -z "$folder_id" ]]; then
      local pf
      pf="$(echo "$resp" | jq -r '.data.parentFolder // .data.folderId // empty')"
      if [[ -n "$pf" ]]; then
        used_folder="$pf"
      fi
    fi

    # Smart guest reuse: if we had no token, try to reuse guest token if API returns it
    if [[ -z "$token" ]]; then
      local gt
      gt="$(echo "$resp" | jq -r '.data.guestToken // .data.token // empty')"
      if [[ -n "$gt" ]]; then
        session_token="$gt"
      fi
    fi
  done

  if [[ "$as_json" -eq 1 ]]; then
    # Build JSON array from line-delimited JSON objects
    jq -s '.' "$tmp_json" | print_json
  fi
  rm -f "$tmp_json"
}

cmd_upload_file_compat() {
  # Backwards compatible with your original:
  # upload-file <filePath> [folderId] [zoneOrServer]
  local filePath="${1-}"
  local folderId="${2-}"
  local zoneOrServer="${3-}"

  [[ -n "$filePath" ]] || die "Usage: $0 upload-file <filePath> [folderId] [zoneOrServer]"

  # Smart fix: allow "upload-file file eu" (zone w/out folder)
  if [[ -z "$zoneOrServer" && ( "$folderId" == "eu" || "$folderId" == "na" ) ]]; then
    zoneOrServer="$folderId"
    folderId=""
  fi

  if [[ -n "$zoneOrServer" && ( "$zoneOrServer" == "eu" || "$zoneOrServer" == "na" ) ]]; then
    cmd_upload "$filePath" --folder "$folderId" --zone "$zoneOrServer" --json
  elif [[ -n "$zoneOrServer" ]]; then
    cmd_upload "$filePath" --folder "$folderId" --server "$zoneOrServer" --json
  else
    cmd_upload "$filePath" --folder "$folderId" --json
  fi
}

cmd_create_folder() {
  # create-folder <parentFolderId> [folderName] [--public true|false]
  require_token

  local parent="${1-}"
  local name="${2-}"
  shift || true
  shift || true

  parent="$(extract_id "${parent:-}")"
  [[ -n "$parent" ]] || die "Usage: $0 create-folder <parentFolderId> [folderName] [--public true|false]"

  local public_val=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --public) public_val="${2-}"; shift 2 ;;
      *) shift ;;
    esac
  done

  local payload
  if [[ -n "$name" ]]; then
    payload="$(jq -n --arg pid "$parent" --arg fn "$name" '{ parentFolderId: $pid, folderName: $fn }')"
  else
    payload="$(jq -n --arg pid "$parent" '{ parentFolderId: $pid }')"
  fi

  if [[ -n "$public_val" ]]; then
    case "$public_val" in
      true|false) payload="$(echo "$payload" | jq --argjson p "$public_val" '. + {public: $p}')" ;;
      *) die "--public must be true or false" ;;
    esac
  fi

  curl_json "POST" "${API_BASE}/contents/createFolder" "$payload" | print_json
}

cmd_update_content() {
  # update-content <contentId> <attribute> <value>
  require_token

  local cid="${1-}"
  local attr="${2-}"
  local val="${3-}"

  cid="$(extract_id "${cid:-}")"

  [[ -n "$cid" && -n "$attr" && -n "$val" ]] || die "Usage: $0 update-content <contentId> <attribute> <value>"

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

  curl_json "PUT" "${API_BASE}/contents/${cid}/update" "$payload" | print_json
}

cmd_delete_content() {
  require_token
  local ids="${1-}"
  [[ -n "$ids" ]] || die "Usage: $0 delete-content <contentIdsCsv>"
  local payload
  payload="$(jq -n --arg cid "$ids" '{ contentsId: $cid }')"
  curl_json "DELETE" "${API_BASE}/contents" "$payload" | print_json
}

cmd_get_content() {
  # get-content <contentId> [--password <plain>] [--password-hash <hash>]
  require_token
  local cid="${1-}"
  [[ -n "$cid" ]] || die "Usage: $0 get-content <contentIdOrUrl> [--password <plain>] [--password-hash <sha256hex>]"
  cid="$(extract_id "$cid")"
  shift || true

  local pw_plain=""
  local pw_hash=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --password) pw_plain="${2-}"; shift 2 ;;
      --password-hash) pw_hash="${2-}"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [[ -n "$pw_plain" && -z "$pw_hash" ]]; then
    pw_hash="$(sha256_hex "$pw_plain")"
  fi

  if [[ -n "$pw_hash" ]]; then
    curl_json_get_urlencoded "${API_BASE}/contents/${cid}" password "$pw_hash" | print_json
  else
    curl_json "GET" "${API_BASE}/contents/${cid}" | print_json
  fi
}

cmd_search_content() {
  # search-content <folderId> <query> [--password <plain>] [--password-hash <hash>]
  require_token
  local folder="${1-}"
  local q="${2-}"
  [[ -n "$folder" && -n "$q" ]] || die "Usage: $0 search-content <folderIdOrUrl> <query> [--password <plain>] [--password-hash <sha256hex>]"
  folder="$(extract_id "$folder")"
  shift 2 || true

  local pw_plain=""
  local pw_hash=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --password) pw_plain="${2-}"; shift 2 ;;
      --password-hash) pw_hash="${2-}"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [[ -n "$pw_plain" && -z "$pw_hash" ]]; then
    pw_hash="$(sha256_hex "$pw_plain")"
  fi

  if [[ -n "$pw_hash" ]]; then
    curl_json_get_urlencoded "${API_BASE}/contents/search" contentId "$folder" searchedString "$q" password "$pw_hash" | print_json
  else
    curl_json_get_urlencoded "${API_BASE}/contents/search" contentId "$folder" searchedString "$q" | print_json
  fi
}

cmd_ls() {
  # ls <folderIdOrUrl> [--json]
  require_token
  local folder="${1-}"
  [[ -n "$folder" ]] || die "Usage: $0 ls <folderIdOrUrl> [--json]"
  folder="$(extract_id "$folder")"
  shift || true

  local as_json=0
  if [[ "${1-}" == "--json" ]]; then
    as_json=1
  fi

  local resp
  resp="$(curl_json "GET" "${API_BASE}/contents/${folder}")"

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
  IFS=',' read -r -a arr <<< "$csv"
  printf '%s\n' "${arr[@]}" | jq -R . | jq -s '.'
}

cmd_create_direct_link() {
  # create-direct-link <contentId> [expireTime] [ipsCsv] [domainsAllowedCsv] [authCsv] [domainsBlockedCsv]
  require_token
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

  curl_json "POST" "${API_BASE}/contents/${cid}/directlinks" "$payload" | print_json
}

cmd_update_direct_link() {
  # update-direct-link <contentId> <directLinkId> [expireTime] [ipsCsv] [domainsAllowedCsv] [authCsv] [domainsBlockedCsv]
  require_token
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

  curl_json "PUT" "${API_BASE}/contents/${cid}/directlinks/${dlid}" "$payload" | print_json
}

cmd_delete_direct_link() {
  require_token
  local cid="${1-}"; cid="$(extract_id "${cid:-}")"
  local dlid="${2-}"
  [[ -n "$cid" && -n "$dlid" ]] || die "Usage: $0 delete-direct-link <contentId> <directLinkId>"
  curl_json "DELETE" "${API_BASE}/contents/${cid}/directlinks/${dlid}" | print_json
}

cmd_copy_content() {
  # copy-content <contentsIdCsv> <destFolderId> [--password ...] [--password-hash ...]
  require_token
  local contents="${1-}"
  local dest="${2-}"
  [[ -n "$contents" && -n "$dest" ]] || die "Usage: $0 copy-content <contentsIdCsv> <destFolderIdOrUrl> [--password <plain>] [--password-hash <sha256hex>]"
  dest="$(extract_id "$dest")"
  shift 2 || true

  local pw_plain=""
  local pw_hash=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --password) pw_plain="${2-}"; shift 2 ;;
      --password-hash) pw_hash="${2-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [[ -n "$pw_plain" && -z "$pw_hash" ]]; then
    pw_hash="$(sha256_hex "$pw_plain")"
  fi

  local payload
  payload="$(jq -n --arg cid "$contents" --arg fid "$dest" '{ contentsId: $cid, folderId: $fid }')"
  if [[ -n "$pw_hash" ]]; then
    payload="$(echo "$payload" | jq --arg p "$pw_hash" '. + {password: $p}')"
  fi

  curl_json "POST" "${API_BASE}/contents/copy" "$payload" | print_json
}

cmd_move_content() {
  # move-content <contentsIdCsv> <destFolderId> [--password ...] [--password-hash ...]
  require_token
  local contents="${1-}"
  local dest="${2-}"
  [[ -n "$contents" && -n "$dest" ]] || die "Usage: $0 move-content <contentsIdCsv> <destFolderIdOrUrl> [--password <plain>] [--password-hash <sha256hex>]"
  dest="$(extract_id "$dest")"
  shift 2 || true

  local pw_plain=""
  local pw_hash=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --password) pw_plain="${2-}"; shift 2 ;;
      --password-hash) pw_hash="${2-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [[ -n "$pw_plain" && -z "$pw_hash" ]]; then
    pw_hash="$(sha256_hex "$pw_plain")"
  fi

  local payload
  payload="$(jq -n --arg cid "$contents" --arg fid "$dest" '{ contentsId: $cid, folderId: $fid }')"
  if [[ -n "$pw_hash" ]]; then
    payload="$(echo "$payload" | jq --arg p "$pw_hash" '. + {password: $p}')"
  fi

  curl_json "PUT" "${API_BASE}/contents/move" "$payload" | print_json
}

cmd_import_content() {
  # import-content <contentsIdCsv> [--password ...] [--password-hash ...]
  require_token
  local contents="${1-}"
  [[ -n "$contents" ]] || die "Usage: $0 import-content <contentsIdCsv> [--password <plain>] [--password-hash <sha256hex>]"
  shift || true

  local pw_plain=""
  local pw_hash=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --password) pw_plain="${2-}"; shift 2 ;;
      --password-hash) pw_hash="${2-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [[ -n "$pw_plain" && -z "$pw_hash" ]]; then
    pw_hash="$(sha256_hex "$pw_plain")"
  fi

  local payload
  payload="$(jq -n --arg cid "$contents" '{ contentsId: $cid }')"
  if [[ -n "$pw_hash" ]]; then
    payload="$(echo "$payload" | jq --arg p "$pw_hash" '. + {password: $p}')"
  fi

  curl_json "POST" "${API_BASE}/contents/import" "$payload" | print_json
}

cmd_get_account_id() {
  require_token
  curl_json "GET" "${API_BASE}/accounts/getid" | print_json
}

cmd_get_account() {
  require_token
  local id="${1-}"
  [[ -n "$id" ]] || die "Usage: $0 get-account <accountId>"
  curl_json "GET" "${API_BASE}/accounts/${id}" | print_json
}

cmd_whoami() {
  require_token
  local resp_id
  resp_id="$(curl_json "GET" "${API_BASE}/accounts/getid")"
  local account_id
  account_id="$(echo "$resp_id" | jq -r '.data.id // empty')"
  [[ -n "$account_id" ]] || die "Could not determine account id"
  local resp_acct
  resp_acct="$(curl_json "GET" "${API_BASE}/accounts/${account_id}")"

  local root
  root="$(echo "$resp_acct" | jq -r '.data.rootFolder // empty')"

  say "Account: $account_id"
  if [[ -n "$root" ]]; then
    say "Root folder: $root"
  else
    say "Root folder: (not present in response)"
  fi
}

cmd_reset_token() {
  require_token
  local id="${1-}"
  [[ -n "$id" ]] || die "Usage: $0 reset-token <accountId>"
  curl_json "POST" "${API_BASE}/accounts/${id}/resettoken" | print_json
}

cmd_hash_password() {
  local pw="${1-}"
  [[ -n "$pw" ]] || die "Usage: $0 hash-password <PASSWORD>"
  sha256_hex "$pw"
}

# --------------------------------------------------
# Main
# --------------------------------------------------

main() {
  need_cmd curl
  need_cmd jq
  init_config

  # Global option parsing
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --token) CLI_TOKEN="${2-}"; shift 2 ;;
      --guest) NO_AUTH=1; shift ;;
      --raw) OUTPUT_MODE="raw"; shift ;;
      --compact) OUTPUT_MODE="compact"; shift ;;
      -v|--verbose) VERBOSE=$((VERBOSE+1)); shift ;;
      -h|--help) usage; exit 0 ;;
      --) shift; break ;;
      *) break ;;
    esac
  done

  local cmd="${1-}"
  shift || true

  case "$cmd" in
    set-token) set_token "${1-}" ;;
    show-token) cmd_show_token ;;
    unset-token) unset_token ;;

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

    get-account-id) cmd_get_account_id ;;
    get-account) cmd_get_account "$@" ;;
    whoami) cmd_whoami ;;
    reset-token) cmd_reset_token "$@" ;;

    ""|help|-h|--help) usage ;;
    *) die "Unknown command: $cmd (run: $0 --help)" ;;
  esac
}

main "$@"
