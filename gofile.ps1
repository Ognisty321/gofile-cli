<#
.SYNOPSIS
    gofile.ps1 - A simple CLI for interacting with the Gofile.io API (Windows/PowerShell version).

.DESCRIPTION
    This script provides functionality equivalent to the original Bash script (gofile.sh),
    adapted for Windows PowerShell.

    Requires PowerShell 7+.

#>

[CmdletBinding()]
param(
    # The main script parameter, e.g. "get-servers"
    [Parameter(Mandatory=$false, Position=0)]
    [string]$COMMAND,

    # All additional arguments go here in an array
    [Parameter(Mandatory=$false, Position=1)]
    [string[]]$ARGS
)

# --------------------------------------------------
# Configuration
# --------------------------------------------------

$CONFIG_DIR  = Join-Path $Env:USERPROFILE ".config\gofile-cli"
$CONFIG_FILE = Join-Path $CONFIG_DIR "config"
$API_BASE    = "https://api.gofile.io"

# --------------------------------------------------
# Helper Functions
# --------------------------------------------------

function Init-Config {
    if (-not (Test-Path $CONFIG_DIR)) {
        New-Item -ItemType Directory -Force -Path $CONFIG_DIR | Out-Null
    }
    if (-not (Test-Path $CONFIG_FILE)) {
        New-Item -ItemType File -Force -Path $CONFIG_FILE | Out-Null
    }
}

function Get-Token {
    if (Test-Path $CONFIG_FILE) {
        $lines = Get-Content $CONFIG_FILE
        foreach ($line in $lines) {
            if ($line -match '^API_TOKEN=(.+)') {
                return $line -replace '^API_TOKEN=', ''
            }
        }
    }
    return ""
}

function Set-Token {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$NewToken
    )
    Init-Config
    $lines = @()
    if (Test-Path $CONFIG_FILE) {
        $lines = Get-Content $CONFIG_FILE | Where-Object { $_ -notmatch '^API_TOKEN=' }
    }
    $lines += "API_TOKEN=$NewToken"
    $lines | Out-File -Encoding utf8 $CONFIG_FILE
    Write-Host "API token saved to $CONFIG_FILE"
}

function Require-Token {
    $token = Get-Token
    if ([string]::IsNullOrWhiteSpace($token)) {
        Write-Host "Error: API token is not set. Run 'gofile.ps1 set-token <YOUR_TOKEN>' first."
        exit 1
    }
}

function Api-Get {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Endpoint
    )
    $token = Get-Token
    try {
        Invoke-RestMethod -Uri "$API_BASE/$Endpoint" `
                          -Headers @{ "Authorization" = "Bearer $token" } `
                          -Method GET
    } catch {
        Write-Error $_
    }
}

function Api-PostJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Endpoint,

        [Parameter(Mandatory=$true)]
        [PSObject]$JsonData
    )
    $token = Get-Token
    try {
        Invoke-RestMethod -Uri "$API_BASE/$Endpoint" `
                          -Method POST `
                          -Headers @{ 
                              "Authorization" = "Bearer $token"
                              "Content-Type"  = "application/json"
                          } `
                          -Body ($JsonData | ConvertTo-Json -Depth 10)
    } catch {
        Write-Error $_
    }
}

function Api-PutJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Endpoint,

        [Parameter(Mandatory=$true)]
        [PSObject]$JsonData
    )
    $token = Get-Token
    try {
        Invoke-RestMethod -Uri "$API_BASE/$Endpoint" `
                          -Method PUT `
                          -Headers @{ 
                              "Authorization" = "Bearer $token"
                              "Content-Type"  = "application/json"
                          } `
                          -Body ($JsonData | ConvertTo-Json -Depth 10)
    } catch {
        Write-Error $_
    }
}

function Api-DeleteJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Endpoint,

        [Parameter(Mandatory=$true)]
        [PSObject]$JsonData
    )
    $token = Get-Token
    try {
        Invoke-RestMethod -Uri "$API_BASE/$Endpoint" `
                          -Method DELETE `
                          -Headers @{
                              "Authorization" = "Bearer $token"
                              "Content-Type"  = "application/json"
                          } `
                          -Body ($JsonData | ConvertTo-Json -Depth 10)
    } catch {
        Write-Error $_
    }
}

function Api-DeleteDirectLink {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Endpoint
    )
    $token = Get-Token
    try {
        Invoke-RestMethod -Uri "$API_BASE/$Endpoint" `
                          -Method DELETE `
                          -Headers @{ "Authorization" = "Bearer $token" }
    } catch {
        Write-Error $_
    }
}

function Show-Usage {
    @"
Usage: .\gofile.ps1 <command> [arguments]

Commands:
  set-token <TOKEN>              Save your Gofile.io API token to config
  show-token                     Print the currently stored API token

  get-servers [zone]            Get available servers (optionally specify zone=eu|na)
  upload-file <filePath> [folderId] [zoneOrServer]
  create-folder <parentFolderId> [folderName]
  update-content <contentId> <attribute> <newValue>
  delete-content <contentIds>
  get-content <contentId>
  search-content <folderId> <searchString>
  create-direct-link <contentId> [expireTime] [ips] [domains] [auth]
  update-direct-link <contentId> <directLinkId> [expireTime] [ips] [domains] [auth]
  delete-direct-link <contentId> <directLinkId>
  copy-content <contentsId> <destFolderId>
  move-content <contentsId> <destFolderId>
  import-content <contentsId>

  get-account-id
  get-account <accountId>
  reset-token <accountId>

Examples:
  .\gofile.ps1 set-token abc123def456
  .\gofile.ps1 get-servers eu
  .\gofile.ps1 upload-file "C:\path\to\video.mp4"
  .\gofile.ps1 update-content MyFolderId name "New Folder Name"
  .\gofile.ps1 reset-token 12345
"@
}

# --------------------------------------------------
# Command Handlers
# --------------------------------------------------

function Cmd-SetToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Token
    )
    if (-not $Token) {
        Write-Host "Usage: .\gofile.ps1 set-token <TOKEN>"
        exit 1
    }
    Set-Token $Token
}

function Cmd-ShowToken {
    [CmdletBinding()]
    param()
    $token = Get-Token
    if ([string]::IsNullOrWhiteSpace($token)) {
        Write-Host "No API token set."
    } else {
        Write-Host "Current API token: $token"
    }
}

function Cmd-GetServers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$Zone
    )
    Require-Token

    $url   = "$API_BASE/servers"
    if ($Zone) { $url += "?zone=$Zone" }
    $token = Get-Token

    $response = Invoke-RestMethod -Uri $url -Headers @{ "Authorization" = "Bearer $token" } -Method GET

    if ($Zone) {
        # Attempt to mimic the zone filter/fallback from the Bash script
        $originalServers   = $response.data.servers
        $serversAllZone    = $response.data.serversAllZone
        $filtered          = $serversAllZone | Where-Object { $_.zone -eq $Zone }

        if (-not $filtered) {
            $response.data.servers = $originalServers
            $response.data | Add-Member -NotePropertyName 'fallbackNotice' -NotePropertyValue "No servers found in zone $Zone, falling back to servers array."
        }
        else {
            $response.data.servers = $filtered
        }
    }

    # Print as JSON
    $response | ConvertTo-Json -Depth 32
}

function Cmd-UploadFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$FilePath,
        [Parameter(Mandatory=$false)] [string]$FolderId,
        [Parameter(Mandatory=$false)] [string]$ZoneOrServer
    )
    Require-Token

    if (-not (Test-Path $FilePath)) {
        Write-Host "File not found: $FilePath"
        exit 1
    }

    # 1) Determine which server to use
    $server = $null
    if ($ZoneOrServer) {
        if ($ZoneOrServer -eq 'eu' -or $ZoneOrServer -eq 'na') {
            $respJson = Cmd-GetServers -Zone $ZoneOrServer | ConvertFrom-Json
            $server   = $respJson.data.servers[0].name
        }
        else {
            # Assume it's a direct server name
            $server = $ZoneOrServer
        }
    }
    else {
        # No zone/server specified; pick the first from default get-servers
        $respJson = Cmd-GetServers | ConvertFrom-Json
        $server   = $respJson.data.servers[0].name
    }

    if (-not $server) {
        Write-Host "No server available or API error."
        exit 1
    }

    $uploadUrl = "https://$server.gofile.io/contents/uploadfile"
    Write-Host "Using server: $server"
    Write-Host "Uploading file: $FilePath"

    $headers = @{ "Authorization" = "Bearer $(Get-Token)" }
    if ($FolderId -and ($FolderId -ne $ZoneOrServer)) {
        Write-Host "Destination folder: $FolderId"
        $form = @{
            file     = Get-Item -Path $FilePath
            folderId = $FolderId
        }
    }
    else {
        $form = @{ file = Get-Item -Path $FilePath }
    }

    try {
        $response = Invoke-WebRequest -Uri $uploadUrl -Method POST -Headers $headers -Form $form
        $response.Content | ConvertFrom-Json | ConvertTo-Json -Depth 32
    } catch {
        Write-Error $_
    }
}

function Cmd-CreateFolder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$ParentFolderId,
        [Parameter(Mandatory=$false)] [string]$FolderName
    )
    Require-Token

    $body = if ($FolderName) {
        @{ parentFolderId = $ParentFolderId; folderName = $FolderName }
    }
    else {
        @{ parentFolderId = $ParentFolderId }
    }

    Api-PostJson "contents/createFolder" $body | ConvertTo-Json -Depth 32
}

function Cmd-UpdateContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$ContentId,
        [Parameter(Mandatory=$true)] [string]$Attribute,
        [Parameter(Mandatory=$true)] [string]$NewValue
    )
    Require-Token

    $body = @{
        attribute      = $Attribute
        attributeValue = $NewValue
    }

    Api-PutJson "contents/$ContentId/update" $body | ConvertTo-Json -Depth 32
}

function Cmd-DeleteContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$ContentsId
    )
    Require-Token

    $body = @{ contentsId = $ContentsId }
    Api-DeleteJson "contents" $body | ConvertTo-Json -Depth 32
}

function Cmd-GetContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$ContentId
    )
    Require-Token

    $token = Get-Token
    Invoke-RestMethod -Uri "$API_BASE/contents/$ContentId" `
                      -Headers @{ "Authorization" = "Bearer $token" } `
                      -Method GET |
        ConvertTo-Json -Depth 32
}

function Cmd-SearchContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$FolderId,
        [Parameter(Mandatory=$true)] [string]$SearchString
    )
    Require-Token

    $token = Get-Token
    $url   = "$API_BASE/contents/search?contentId=$FolderId&searchedString=$SearchString"
    Invoke-RestMethod -Uri $url `
                      -Headers @{ "Authorization" = "Bearer $token" } `
                      -Method GET |
        ConvertTo-Json -Depth 32
}

function Cmd-CreateDirectLink {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$ContentId,
        [Parameter(Mandatory=$false)] [string]$ExpireTime,
        [Parameter(Mandatory=$false)] [string]$SourceIpsAllowed,
        [Parameter(Mandatory=$false)] [string]$DomainsAllowed,
        [Parameter(Mandatory=$false)] [string]$Auth
    )
    Require-Token

    $payload = [Ordered]@{}
    if ($ExpireTime)       { $payload.expireTime       = [int]$ExpireTime }
    if ($SourceIpsAllowed) { $payload.sourceIpsAllowed = $SourceIpsAllowed -split ',' }
    if ($DomainsAllowed)   { $payload.domainsAllowed   = $DomainsAllowed   -split ',' }
    if ($Auth)             { $payload.auth             = $Auth             -split ',' }

    Api-PostJson "contents/$ContentId/directlinks" $payload | ConvertTo-Json -Depth 32
}

function Cmd-UpdateDirectLink {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$ContentId,
        [Parameter(Mandatory=$true)] [string]$DirectLinkId,
        [Parameter(Mandatory=$false)] [string]$ExpireTime,
        [Parameter(Mandatory=$false)] [string]$SourceIpsAllowed,
        [Parameter(Mandatory=$false)] [string]$DomainsAllowed,
        [Parameter(Mandatory=$false)] [string]$Auth
    )
    Require-Token

    $payload = [Ordered]@{}
    if ($ExpireTime)       { $payload.expireTime       = [int]$ExpireTime }
    if ($SourceIpsAllowed) { $payload.sourceIpsAllowed = $SourceIpsAllowed -split ',' }
    if ($DomainsAllowed)   { $payload.domainsAllowed   = $DomainsAllowed   -split ',' }
    if ($Auth)             { $payload.auth             = $Auth             -split ',' }

    Api-PutJson "contents/$ContentId/directlinks/$DirectLinkId" $payload | ConvertTo-Json -Depth 32
}

function Cmd-DeleteDirectLink {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$ContentId,
        [Parameter(Mandatory=$true)] [string]$DirectLinkId
    )
    Require-Token

    Api-DeleteDirectLink "contents/$ContentId/directlinks/$DirectLinkId" | ConvertTo-Json -Depth 32
}

function Cmd-CopyContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$ContentsId,
        [Parameter(Mandatory=$true)] [string]$FolderId
    )
    Require-Token

    $body = @{ contentsId = $ContentsId; folderId = $FolderId }
    Api-PostJson "contents/copy" $body | ConvertTo-Json -Depth 32
}

function Cmd-MoveContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$ContentsId,
        [Parameter(Mandatory=$true)] [string]$FolderId
    )
    Require-Token

    $body = @{ contentsId = $ContentsId; folderId = $FolderId }
    Api-PutJson "contents/move" $body | ConvertTo-Json -Depth 32
}

function Cmd-ImportContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$ContentsId
    )
    Require-Token

    $body = @{ contentsId = $ContentsId }
    Api-PostJson "contents/import" $body | ConvertTo-Json -Depth 32
}

function Cmd-GetAccountId {
    [CmdletBinding()]
    param()
    Require-Token
    Api-Get "accounts/getid" | ConvertTo-Json -Depth 32
}

function Cmd-GetAccount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$AccountId
    )
    Require-Token
    Api-Get "accounts/$AccountId" | ConvertTo-Json -Depth 32
}

function Cmd-ResetToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$AccountId
    )
    Require-Token

    $token = Get-Token
    try {
        Invoke-RestMethod -Uri "$API_BASE/accounts/$AccountId/resettoken" `
                          -Headers @{ "Authorization" = "Bearer $token" } `
                          -Method POST |
        ConvertTo-Json -Depth 32
    } catch {
        Write-Error $_
    }
}

# --------------------------------------------------
# Main
# --------------------------------------------------

Init-Config

switch -Wildcard ($COMMAND) {
    "set-token"          { Cmd-SetToken @ARGS }
    "show-token"         { Cmd-ShowToken }
    "get-servers"        { Cmd-GetServers @ARGS }
    "upload-file"        { Cmd-UploadFile @ARGS }
    "create-folder"      { Cmd-CreateFolder @ARGS }
    "update-content"     { Cmd-UpdateContent @ARGS }
    "delete-content"     { Cmd-DeleteContent @ARGS }
    "get-content"        { Cmd-GetContent @ARGS }
    "search-content"     { Cmd-SearchContent @ARGS }
    "create-direct-link" { Cmd-CreateDirectLink @ARGS }
    "update-direct-link" { Cmd-UpdateDirectLink @ARGS }
    "delete-direct-link" { Cmd-DeleteDirectLink @ARGS }
    "copy-content"       { Cmd-CopyContent @ARGS }
    "move-content"       { Cmd-MoveContent @ARGS }
    "import-content"     { Cmd-ImportContent @ARGS }
    "get-account-id"     { Cmd-GetAccountId }
    "get-account"        { Cmd-GetAccount @ARGS }
    "reset-token"        { Cmd-ResetToken @ARGS }
    default              { Show-Usage }
}
