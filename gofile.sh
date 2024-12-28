#!/usr/bin/env bash
#
# gofile.sh - A simple CLI for interacting with the Gofile.io API.
#
# Requires: curl, jq
#
# Usage:
#   ./gofile.sh <command> [options...]
#

# --------------------------------------------------
# Configuration
# --------------------------------------------------

CONFIG_DIR="$HOME/.config/gofile-cli"
CONFIG_FILE="$CONFIG_DIR/config"
API_BASE="https://api.gofile.io"

# --------------------------------------------------
# Helper Functions
# --------------------------------------------------

init_config() {
  [ ! -d "$CONFIG_DIR" ] && mkdir -p "$CONFIG_DIR"
  [ ! -f "$CONFIG_FILE" ] && touch "$CONFIG_FILE"
}

get_token() {
  if [ -f "$CONFIG_FILE" ]; then
    grep "^API_TOKEN=" "$CONFIG_FILE" | cut -d '=' -f2-
  else
    echo ""
  fi
}

set_token() {
  local new_token="$1"
  init_config
  # Overwrite any existing token line
  sed -i '/^API_TOKEN=/d' "$CONFIG_FILE"
  echo "API_TOKEN=$new_token" >> "$CONFIG_FILE"
  echo "API token saved to $CONFIG_FILE"
}

require_token() {
  local token
  token=$(get_token)
  if [ -z "$token" ]; then
    echo "Error: API token is not set. Run 'gofile.sh set-token <YOUR_TOKEN>' first."
    exit 1
  fi
}

# Generic GET
api_get() {
  local endpoint="$1"
  local token
  token=$(get_token)
  curl -s -H "Authorization: Bearer ${token}" "${API_BASE}/${endpoint}"
}

# Generic POST with JSON
api_post_json() {
  local endpoint="$1"
  local json_data="$2"
  local token
  token=$(get_token)
  curl -s -X POST \
       -H "Authorization: Bearer ${token}" \
       -H "Content-Type: application/json" \
       -d "${json_data}" \
       "${API_BASE}/${endpoint}"
}

# Generic POST with multipart form-data
api_post_multipart() {
  local endpoint="$1"
  shift
  local token
  token=$(get_token)
  curl -s -X POST \
       -H "Authorization: Bearer ${token}" \
       -F "$@" \
       "${endpoint}"
}

# Generic PUT with JSON
api_put_json() {
  local endpoint="$1"
  local json_data="$2"
  local token
  token=$(get_token)
  curl -s -X PUT \
       -H "Authorization: Bearer ${token}" \
       -H "Content-Type: application/json" \
       -d "${json_data}" \
       "${API_BASE}/${endpoint}"
}

# Generic DELETE with JSON
api_delete_json() {
  local endpoint="$1"
  local json_data="$2"
  local token
  token=$(get_token)
  curl -s -X DELETE \
       -H "Authorization: Bearer ${token}" \
       -H "Content-Type: application/json" \
       -d "${json_data}" \
       "${API_BASE}/${endpoint}"
}

# DELETE for direct links
api_delete_direct_link() {
  local endpoint="$1"
  local token
  token=$(get_token)
  curl -s -X DELETE \
       -H "Authorization: Bearer ${token}" \
       "${API_BASE}/${endpoint}"
}

usage() {
  cat <<EOF
Usage: $0 <command> [arguments]

Commands:
  set-token <TOKEN>              Save your Gofile.io API token to config
  show-token                     Print the currently stored API token

  get-servers [zone]            Get available servers (optionally specify zone=eu|na)
  upload-file <filePath> [folderId] [zoneOrServer]
                                Upload a file. 
                                If [zoneOrServer] is "eu" or "na", pick first server in that zone.
                                If [zoneOrServer] is e.g. "store6", upload directly to that server.

  create-folder <parentFolderId> [folderName]
  update-content <contentId> <attribute> <newValue>
  delete-content <contentIds>
  get-content <contentId>
  search-content <folderId> <searchString>
  create-direct-link <contentId> [expireTime] [sourceIpsAllowed] [domainsAllowed] [auth]
  update-direct-link <contentId> <directLinkId> [expireTime] [sourceIpsAllowed] [domainsAllowed] [auth]
  delete-direct-link <contentId> <directLinkId>
  copy-content <contentsId> <destFolderId>
  move-content <contentsId> <destFolderId>
  import-content <contentsId>

  get-account-id
  get-account <accountId>
  reset-token <accountId>

Examples:
  $0 set-token abc123def456
  $0 get-servers eu
  $0 upload-file "video.mp4"
  $0 upload-file "video.mp4" MyFolderId eu
  $0 upload-file "video.mp4" MyFolderId store6
  $0 update-content MyFolderId name "New Folder Name"
  $0 reset-token 12345
EOF
}

# --------------------------------------------------
# Command Handlers
# --------------------------------------------------

cmd_set_token() {
  local token="$1"
  if [ -z "$token" ]; then
    echo "Usage: $0 set-token <TOKEN>"
    exit 1
  fi
  set_token "$token"
}

cmd_show_token() {
  local token
  token=$(get_token)
  if [ -z "$token" ]; then
    echo "No API token set."
  else
    echo "Current API token: $token"
  fi
}

cmd_get_servers() {
  require_token
  local zone="$1"
  local url="${API_BASE}/servers"

  if [ -n "$zone" ]; then
    url="${url}?zone=${zone}"
  fi

  local response
  response=$(curl -s -H "Authorization: Bearer $(get_token)" "$url")

  if [ -n "$zone" ]; then
    # Attempt to filter strictly for that zone
    echo "$response" | jq --arg zone "$zone" '
      # Capture original .data.servers in $orig
      # Capture .data.serversAllZone in $all
      .data.servers as $orig
      | .data.serversAllZone as $all
      | .data.servers = (
          # Filter for the specified zone
          $all | map(select(.zone == $zone))
        )
      |
      # If the filtered list is empty, revert to $orig or do something custom
      if (.data.servers | length) == 0 then
        .data.servers = $orig
        | .data.fallbackNotice = "No servers found in zone \($zone), falling back to servers array."
      else
        .
      end
    '
  else
    # No zone requested, just print the raw response
    echo "$response" | jq
  fi
}

##
# Upload a file:
#   upload-file <filePath> [folderId] [zoneOrServer]
#
# If zoneOrServer is "eu" or "na", we pick .data.servers[0].name from that zone
# If zoneOrServer is a server name (e.g., "store6"), we use that server directly
# If nothing is provided, we pick .data.servers[0].name from a default get-servers call
##
cmd_upload_file() {
  require_token

  local filePath="$1"
  local folderId="$2"
  local zoneOrServer="$3"

  if [ -z "$filePath" ]; then
    echo "Usage: $0 upload-file <filePath> [folderId] [zoneOrServer]"
    exit 1
  fi

  # 1) Determine which server to use
  local server=""
  if [ -n "$zoneOrServer" ]; then
    # If the user typed "eu" or "na", we do a get-servers call with that zone and pick the first.
    if [ "$zoneOrServer" = "eu" ] || [ "$zoneOrServer" = "na" ]; then
      server=$(cmd_get_servers "$zoneOrServer" | jq -r '.data.servers[0].name // empty')
    else
      # Assume it's an actual server name like "store6"
      server="$zoneOrServer"
    fi
  else
    # No zone/server specified; just pick the first from the default /servers call
    server=$(cmd_get_servers | jq -r '.data.servers[0].name // empty')
  fi

  if [ -z "$server" ]; then
    echo "No server available or API error."
    exit 1
  fi

  local upload_url="https://${server}.gofile.io/contents/uploadfile"

  # 2) Upload the file
  echo "Using server: $server"
  echo "Uploading file: $filePath"

  if [ -n "$folderId" ] && [ "$folderId" != "$zoneOrServer" ]; then
    echo "Destination folder: $folderId"
    api_post_multipart "$upload_url" \
      "file=@\"$filePath\"" \
      "folderId=$folderId" | jq
  else
    api_post_multipart "$upload_url" \
      "file=@\"$filePath\"" | jq
  fi
}

cmd_create_folder() {
  require_token
  local parentFolderId="$1"
  local folderName="$2"

  if [ -z "$parentFolderId" ]; then
    echo "Usage: $0 create-folder <parentFolderId> [folderName]"
    exit 1
  fi

  local payload
  if [ -n "$folderName" ]; then
    payload=$(jq -n \
      --arg pid "$parentFolderId" \
      --arg fn "$folderName" \
      '{ parentFolderId: $pid, folderName: $fn }')
  else
    payload=$(jq -n \
      --arg pid "$parentFolderId" \
      '{ parentFolderId: $pid }')
  fi

  api_post_json "contents/createFolder" "$payload" | jq
}

cmd_update_content() {
  require_token
  local contentId="$1"
  local attribute="$2"
  local attributeValue="$3"

  if [ -z "$contentId" ] || [ -z "$attribute" ] || [ -z "$attributeValue" ]; then
    echo "Usage: $0 update-content <contentId> <attribute> <newValue>"
    exit 1
  fi

  local payload
  payload=$(jq -n \
    --arg attr "$attribute" \
    --arg val "$attributeValue" \
    '{ attribute: $attr, attributeValue: $val }')

  api_put_json "contents/${contentId}/update" "$payload" | jq
}

cmd_delete_content() {
  require_token
  local contentsId="$1"

  if [ -z "$contentsId" ]; then
    echo "Usage: $0 delete-content <contentIds>"
    exit 1
  fi

  local payload
  payload=$(jq -n \
    --arg cid "$contentsId" \
    '{ contentsId: $cid }')

  api_delete_json "contents" "$payload" | jq
}

cmd_get_content() {
  require_token
  local contentId="$1"
  if [ -z "$contentId" ]; then
    echo "Usage: $0 get-content <contentId>"
    exit 1
  fi

  curl -s -H "Authorization: Bearer $(get_token)" \
    "${API_BASE}/contents/${contentId}" | jq
}

cmd_search_content() {
  require_token
  local folderId="$1"
  local searchString="$2"

  if [ -z "$folderId" ] || [ -z "$searchString" ]; then
    echo "Usage: $0 search-content <folderId> <searchString>"
    exit 1
  fi

  local url="${API_BASE}/contents/search?contentId=${folderId}&searchedString=${searchString}"
  curl -s -H "Authorization: Bearer $(get_token)" "$url" | jq
}

cmd_create_direct_link() {
  require_token
  local contentId="$1"
  local expireTime="$2"
  local sourceIpsAllowed="$3"
  local domainsAllowed="$4"
  local auth="$5"

  if [ -z "$contentId" ]; then
    echo "Usage: $0 create-direct-link <contentId> [expireTime] [ips] [domains] [auth]"
    exit 1
  fi

  local payload="{}"
  [ -n "$expireTime" ] && payload=$(echo "$payload" | jq --arg et "$expireTime" '. + {expireTime: ($et|tonumber)}')

  if [ -n "$sourceIpsAllowed" ]; then
    IFS=',' read -r -a ipsArray <<< "$sourceIpsAllowed"
    local ipsJson
    ipsJson=$(jq -n --argjson list "$(printf '%s\n' "${ipsArray[@]}" | jq -R . | jq -s .)" '$list')
    payload=$(echo "$payload" | jq --argjson data "$ipsJson" '. + {sourceIpsAllowed: $data}')
  fi

  if [ -n "$domainsAllowed" ]; then
    IFS=',' read -r -a domArray <<< "$domainsAllowed"
    local domJson
    domJson=$(jq -n --argjson list "$(printf '%s\n' "${domArray[@]}" | jq -R . | jq -s .)" '$list')
    payload=$(echo "$payload" | jq --argjson data "$domJson" '. + {domainsAllowed: $data}')
  fi

  if [ -n "$auth" ]; then
    IFS=',' read -r -a authArray <<< "$auth"
    local authJson
    authJson=$(jq -n --argjson list "$(printf '%s\n' "${authArray[@]}" | jq -R . | jq -s .)" '$list')
    payload=$(echo "$payload" | jq --argjson data "$authJson" '. + {auth: $data}')
  fi

  api_post_json "contents/${contentId}/directlinks" "$payload" | jq
}

cmd_update_direct_link() {
  require_token
  local contentId="$1"
  local directLinkId="$2"
  local expireTime="$3"
  local sourceIpsAllowed="$4"
  local domainsAllowed="$5"
  local auth="$6"

  if [ -z "$contentId" ] || [ -z "$directLinkId" ]; then
    echo "Usage: $0 update-direct-link <contentId> <directLinkId> [expireTime] [ips] [domains] [auth]"
    exit 1
  fi

  local payload="{}"
  [ -n "$expireTime" ] && payload=$(echo "$payload" | jq --arg et "$expireTime" '. + {expireTime: ($et|tonumber)}')

  if [ -n "$sourceIpsAllowed" ]; then
    IFS=',' read -r -a ipsArray <<< "$sourceIpsAllowed"
    local ipsJson
    ipsJson=$(jq -n --argjson list "$(printf '%s\n' "${ipsArray[@]}" | jq -R . | jq -s .)" '$list')
    payload=$(echo "$payload" | jq --argjson data "$ipsJson" '. + {sourceIpsAllowed: $data}')
  fi

  if [ -n "$domainsAllowed" ]; then
    IFS=',' read -r -a domArray <<< "$domainsAllowed"
    local domJson
    domJson=$(jq -n --argjson list "$(printf '%s\n' "${domArray[@]}" | jq -R . | jq -s .)" '$list')
    payload=$(echo "$payload" | jq --argjson data "$domJson" '. + {domainsAllowed: $data}')
  fi

  if [ -n "$auth" ]; then
    IFS=',' read -r -a authArray <<< "$auth"
    local authJson
    authJson=$(jq -n --argjson list "$(printf '%s\n' "${authArray[@]}" | jq -R . | jq -s .)" '$list')
    payload=$(echo "$payload" | jq --argjson data "$authJson" '. + {auth: $data}')
  fi

  api_put_json "contents/${contentId}/directlinks/${directLinkId}" "$payload" | jq
}

cmd_delete_direct_link() {
  require_token
  local contentId="$1"
  local directLinkId="$2"
  if [ -z "$contentId" ] || [ -z "$directLinkId" ]; then
    echo "Usage: $0 delete-direct-link <contentId> <directLinkId>"
    exit 1
  fi
  api_delete_direct_link "contents/${contentId}/directlinks/${directLinkId}" | jq
}

cmd_copy_content() {
  require_token
  local contentsId="$1"
  local folderId="$2"
  if [ -z "$contentsId" ] || [ -z "$folderId" ]; then
    echo "Usage: $0 copy-content <contentsId> <destFolderId>"
    exit 1
  fi

  local payload
  payload=$(jq -n \
    --arg cid "$contentsId" \
    --arg fid "$folderId" \
    '{ contentsId: $cid, folderId: $fid }')

  api_post_json "contents/copy" "$payload" | jq
}

cmd_move_content() {
  require_token
  local contentsId="$1"
  local folderId="$2"
  if [ -z "$contentsId" ] || [ -z "$folderId" ]; then
    echo "Usage: $0 move-content <contentsId> <destFolderId>"
    exit 1
  fi

  local payload
  payload=$(jq -n \
    --arg cid "$contentsId" \
    --arg fid "$folderId" \
    '{ contentsId: $cid, folderId: $fid }')

  api_put_json "contents/move" "$payload" | jq
}

cmd_import_content() {
  require_token
  local contentsId="$1"
  if [ -z "$contentsId" ]; then
    echo "Usage: $0 import-content <contentsId>"
    exit 1
  fi

  local payload
  payload=$(jq -n --arg cid "$contentsId" '{ contentsId: $cid }')
  api_post_json "contents/import" "$payload" | jq
}

cmd_get_account_id() {
  require_token
  api_get "accounts/getid" | jq
}

cmd_get_account() {
  require_token
  local accountId="$1"
  if [ -z "$accountId" ]; then
    echo "Usage: $0 get-account <accountId>"
    exit 1
  fi
  api_get "accounts/${accountId}" | jq
}

cmd_reset_token() {
  require_token
  local accountId="$1"
  if [ -z "$accountId" ]; then
    echo "Usage: $0 reset-token <accountId>"
    exit 1
  fi

  curl -s -X POST \
    -H "Authorization: Bearer $(get_token)" \
    "${API_BASE}/accounts/${accountId}/resettoken" | jq
}

# --------------------------------------------------
# Main
# --------------------------------------------------

init_config

COMMAND="$1"
shift || true

case "$COMMAND" in
  set-token)          cmd_set_token "$@" ;;
  show-token)         cmd_show_token ;;
  get-servers)        cmd_get_servers "$@" ;;
  upload-file)        cmd_upload_file "$@" ;;
  create-folder)      cmd_create_folder "$@" ;;
  update-content)     cmd_update_content "$@" ;;
  delete-content)     cmd_delete_content "$@" ;;
  get-content)        cmd_get_content "$@" ;;
  search-content)     cmd_search_content "$@" ;;
  create-direct-link) cmd_create_direct_link "$@" ;;
  update-direct-link) cmd_update_direct_link "$@" ;;
  delete-direct-link) cmd_delete_direct_link "$@" ;;
  copy-content)       cmd_copy_content "$@" ;;
  move-content)       cmd_move_content "$@" ;;
  import-content)     cmd_import_content "$@" ;;
  get-account-id)     cmd_get_account_id ;;
  get-account)        cmd_get_account "$@" ;;
  reset-token)        cmd_reset_token "$@" ;;
  *)                  usage ;;
esac
