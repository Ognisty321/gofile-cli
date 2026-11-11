# Gofile CLI (Bash)

A robust Bash CLI (`gofile.sh`) for interacting with the Gofile.io API. Upload files (single or multiple), manage folders and content, search, create direct links, and handle account actions from your terminal.

> Uploads default to Gofile’s **global upload endpoint**, and the CLI can reuse the returned `parentFolder`/`guestToken` to keep multiple uploads in the same folder automatically.

> The Gofile API is currently in beta ([reference](https://gofile.io/api)). Most operations require a token. Uploading, creating folders, updating and deleting content work with any account (including guests); listing (`get-content`, `ls`), `search-content`, `copy-content`, `move-content`, `import-content` and direct links require a Premium account.

---

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [Usage](#usage)
  - [Global Options](#global-options)
  - [Commands](#commands)
- [Examples](#examples)
- [Network settings](#network-settings)
- [Development](#development)
- [License](#license)

---

## Features

- **Token management**
  - Store your token in `~/.config/gofile-cli/config` (XDG-aware).
  - Support for `--token` (per-command override) and `GOFILE_TOKEN` env var.
  - `show-token` prints a **masked** token.

- **Guest mode**
  - Run commands without auth via `--guest` (useful for basic uploads / public operations).

- **Smarter uploads**
  - Uses Gofile’s **global upload endpoint** by default.
  - Upload **multiple files** in one command; if you don’t pass `--folder`, the CLI reuses the folder returned by the first upload.
  - Optional `--progress` for a progress bar.
  - Official regional endpoints via `--region`; compatibility aliases via `--zone eu|na`.
  - Validates every input file before the first upload starts.
  - Refuses to send an account token to a non-Gofile custom URL.

- **More ergonomic commands**
  - `ls` prints a human-friendly listing of a folder.
  - Aliases: `servers`, `mkdir`, `rm`, `search`.

- **Password hashing support**
  - Some API endpoints accept/require a **SHA-256 hex password hash**; the CLI supports `--password` (hashes for you) and `--password-hash` (use your own).
  - Helper command: `hash-password`.

- **Direct links improvements**
  - Create/update direct links with IP/domain allowlists, auth pairs, **and domainsBlocked**.
  - Updates keep omitted restrictions; `none` removes one.

- **Listing options**
  - Pagination, sorting, filtering and nested depth for `get-content` / `ls`; creation-time range for `search-content`.

- **Better output and error handling**
  - Default pretty JSON output; switch to raw/compact when needed.
  - Fails clearly on invalid options, network failures, HTTP errors, and API errors, with a hint for common API statuses (`error-token`, `error-notPremium`, `error-rateLimit`, ...).
  - Warns when a share code is passed where the API needs a content UUID.
  - Configurable connect and total request timeouts.

- **Quality checks**
  - ShellCheck static analysis.
  - Automated smoke tests and GitHub Actions CI.

---

## Requirements

1. **Bash** (Linux; macOS and WSL typically work too)
2. **curl**
3. **jq**
4. For password hashing (one of):
   - `sha256sum` (GNU), or `shasum` (macOS), or `openssl`

---

## Installation

1. Clone this repository:
   ```bash
   git clone https://github.com/Ognisty321/gofile-cli.git
   cd gofile-cli
   ```

2. Make the script executable:

   ```bash
   chmod +x gofile.sh
   ```

3. (Optional) Put it on your PATH:

   ```bash
   sudo cp gofile.sh /usr/local/bin/gofile
   # or:
   # ln -s "$PWD/gofile.sh" /usr/local/bin/gofile
   ```

Now you can run `./gofile.sh` (or `gofile` if it’s in your PATH).

---

## Configuration

### Set your token (recommended)

```bash
./gofile.sh set-token <YOUR_API_TOKEN>
./gofile.sh show-token
```

Config file location (XDG-aware):

* Default: `~/.config/gofile-cli/config`

### Alternative: environment variable

```bash
export GOFILE_TOKEN="<YOUR_API_TOKEN>"
./gofile.sh get-account-id
```

### Alternative: per-command token override

```bash
./gofile.sh --token "<YOUR_API_TOKEN>" get-account-id
```

### Remove token from config

```bash
./gofile.sh unset-token
```

---

## Usage

```text
Usage:
  ./gofile.sh [global options] <command> [args...]
```

### Global Options

* `--token <TOKEN>`: use TOKEN for this invocation (overrides config/env)
* `--guest`: do NOT send Authorization header for this invocation
* `-v, --verbose`: verbose output (repeat for more)
* `--raw`: print raw JSON (no jq formatting)
* `--compact`: print compact JSON (`jq -c`)
* `--version`: show the CLI version
* `-h, --help`: show help

---

## Commands

### Token management

* `set-token <TOKEN>`
  Save token to config

* `show-token`
  Show token (masked)

* `unset-token`
  Remove token from config

* `hash-password <PASSWORD>`
  Print SHA-256 hex hash (useful for endpoints requiring password hashes)

---

### Servers

* `get-servers [zone]` (alias: `servers`)
  Get available storage servers. Optional zone: `eu` | `na`.
  This legacy endpoint still responds but is no longer part of the official API reference; uploads do not need it.

---

### Upload

* `upload <file...> [--folder <folderId>] [--region <region>] [--zone eu|na] [--server storeX] [--url <uploadUrl>] [--allow-custom-auth] [--progress] [--json]`

  Notes:

  * Uses the **global upload endpoint** by default.
  * If `--folder` is omitted, the CLI reuses the folder returned by the first upload when uploading multiple files.
  * `--folder` takes the destination folder **UUID** (share codes are not accepted for uploads).
  * Supported regions: `eu-par`, `na-phx`, `na-nyc`, `ap-sgp`, `ap-hkg`, `ap-tyo`, `ap-syd`, `sa-sao`.
  * `--zone eu|na` remains available as an alias for `--region eu-par|na-phx`.
  * `--server` uses the legacy storage-server endpoint.
  * `--region`, `--zone`, `--server`, and `--url` are mutually exclusive.
  * Custom upload URLs must use HTTPS. When a token is active, only official `*.gofile.io` URLs are accepted by default. Use global `--guest` for an unauthenticated custom upload or explicitly pass `--allow-custom-auth` if you trust the custom endpoint.

* `upload-file <filePath> [folderId] [zoneOrServer]`
  Backwards-compatible wrapper for older usage (prefer `upload` going forward).

---

### Folders & contents

* `create-folder <parentFolderId> [folderName] [--public true|false]` (alias: `mkdir`)
* `ls <idOrCodeOrUrl> [read options] [--json]`
* `get-content <idOrCodeOrUrl> [read options]`
* `search-content <idOrCodeOrUrl> <searchString> [--password <pw> | --password-hash <sha256hex>] [--created-from <unix>] [--created-to <unix>]` (alias: `search`)
* `update-content <contentId> <attribute> <newValue> [--delete-after-expiry] [--no-hash]`
* `delete-content <contentIdsCsv>` (alias: `rm`)
* `copy-content <contentsIdCsv> <destFolderId> [--password <pw> | --password-hash <sha256hex>]`
* `move-content <contentsIdCsv> <destFolderId>`
* `import-content <contentsIdCsv> [--password <pw> | --password-hash <sha256hex>]`

Read options for `get-content` and `ls`:

| Option | Meaning |
| --- | --- |
| `--password <pw>` / `--password-hash <sha256hex>` | Password of a protected folder |
| `--page <n>`, `--page-size <n>` | Pagination (totals are returned in `metadata`) |
| `--sort-field <field>` | `createTime` (default), `name`, `size`, `downloads`, `mimetype` |
| `--sort-direction asc\|desc` | Sort order (`1` / `-1` are accepted too) |
| `--filter <text>` | Case-insensitive substring filter on child names and tags |
| `--max-depth <1-16>` | Depth of nested children (default 1) |

Attributes for `update-content`:

| Attribute | Applies to | Value |
| --- | --- | --- |
| `name` | files & folders | New name (max 255 characters) |
| `description` | folders | Text, max 2,000 characters; `""` removes it |
| `tags` | files & folders | Comma-separated tags; `""` removes them |
| `public` | folders | `true` / `false` |
| `password` | folders | 4–100 characters; `""` removes it |
| `expiry` | folders | Unix timestamp; `""` removes it |
| `modTime` | files & folders | Unix timestamp |

* The password is stored as its SHA-256 hash, which is what `--password` sends when reading the folder. Use `--no-hash` to send the value unchanged.
* On Premium accounts an expired folder is kept unless `--delete-after-expiry` is passed. On guest/standard accounts an expired folder is **permanently deleted** with everything inside it.

> Tip: content IDs are UUIDs. `get-content`, `ls` and `search-content` also accept a share code or a share URL like `https://gofile.io/d/AbCdEf`. Every command that modifies content needs the UUID; the CLI warns when it gets something else.

---

### Direct links

* `create-direct-link <contentId> [expireTime] [sourceIpsAllowedCsv] [domainsAllowedCsv] [authCsv] [domainsBlockedCsv]`
* `update-direct-link <contentId> <directLinkId> [expireTime] [sourceIpsAllowedCsv] [domainsAllowedCsv] [authCsv] [domainsBlockedCsv]`
* `delete-direct-link <contentId> <directLinkId>`

> Pass `""` to skip a positional field. When updating, skipped fields keep their current value; pass `none` to remove a restriction (for `expireTime`, `none` means "never expires").

---

### Account

* `create-account [email]`
  Without an email: creates a guest account and prints its token (save it, it is the only way back in). With an email: creates a standard account and Gofile emails a sign-in link. No token is sent with this request.
* `get-account-id`
* `get-account <accountId>`
* `whoami`
  Prints account id + root folder id (if available)
* `reset-token <accountId>`
  Invalidates your token and triggers a new one (sent via Gofile email). Never use it on a guest account: the new token cannot be delivered and the account is lost.

---

## Examples

### 1) Set token and check identity

```bash
./gofile.sh set-token abc123def456
./gofile.sh show-token
./gofile.sh whoami
```

### 2) Upload a single file (default global upload)

```bash
./gofile.sh upload "/path/to/video.mp4" --progress
```

### 3) Upload multiple files into the same folder automatically

```bash
./gofile.sh upload ./a.bin ./b.bin ./c.bin --progress
```

### 4) Upload to a specific folder

```bash
./gofile.sh upload "./video.mp4" --folder <folderUuid>
```

### 5) Regional upload (optional)

```bash
./gofile.sh upload "./video.mp4" --region eu-par
# compatibility alias:
./gofile.sh upload "./video.mp4" --zone eu
# legacy server selection:
./gofile.sh upload "./video.mp4" --server store6
```

### 6) List a folder by URL

```bash
./gofile.sh ls https://gofile.io/d/AbCdEf
./gofile.sh ls https://gofile.io/d/AbCdEf --sort-field name --sort-direction asc --page-size 100
```

### 7) Search with spaces (URL-encoded safely)

```bash
./gofile.sh search-content MyFolderId "music files"
```

### 8) Password hashing helper + protected content access

```bash
./gofile.sh hash-password "secret"
./gofile.sh get-content MyFolderId --password "secret"
# or:
./gofile.sh get-content MyFolderId --password-hash <sha256hex>
```

### 9) Create a direct link with restrictions

```bash
./gofile.sh create-direct-link <fileUuid> 1786051200 "203.0.113.10" "example.com" "alice:secret" "bad.com"
# later: drop the IP allowlist and the expiry, keep everything else
./gofile.sh update-direct-link <fileUuid> <directLinkId> none none
```

### 10) Protect a folder and set an expiry

```bash
./gofile.sh update-content <folderUuid> password "secret"
./gofile.sh update-content <folderUuid> expiry 1786051200
./gofile.sh update-content <folderUuid> password ""   # remove the password
```

---

## Network settings

The following optional environment variables control requests:

* `GOFILE_CONNECT_TIMEOUT`: connection timeout in seconds (default: `15`)
* `GOFILE_MAX_TIME`: maximum total request time in seconds (default: `0`, unlimited)
* `GOFILE_API_BASE`: alternate API base URL
* `GOFILE_UPLOAD_URL`: alternate default upload URL

For large uploads, keep `GOFILE_MAX_TIME=0` or choose a suitably high value.

---

## Development

Run the local checks with:

```bash
shellcheck --severity=style gofile.sh tests/smoke.sh
bash tests/smoke.sh
```

The smoke tests use a local mock and do not upload or delete remote content.

---

## License

MIT License. See [LICENSE](LICENSE).
