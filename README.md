# Gofile CLI (Bash)

A simple but robust Bash CLI (`gofile.sh`) for interacting with the Gofile.io API. Upload files (single or multiple), manage folders/contents, search, create direct links, and handle account actions, straight from your terminal.

> Uploads default to Gofile’s **global upload endpoint**, and the CLI can reuse the returned `folderId`/`guestToken` to keep multiple uploads in the same folder automatically.

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
  - Optional server selection by `--zone eu|na` or `--server storeX` (legacy-style).

- **More ergonomic commands**
  - `ls` prints a human-friendly listing of a folder.
  - Aliases: `servers`, `mkdir`, `rm`, `search`.

- **Password hashing support**
  - Some API endpoints accept/require a **SHA-256 hex password hash**; the CLI supports `--password` (hashes for you) and `--password-hash` (use your own).
  - Helper command: `hash-password`.

- **Direct links improvements**
  - Create/update direct links with IP/domain allowlists, auth pairs, **and domainsBlocked**.

- **Better output and error handling**
  - Default pretty JSON output; switch to raw/compact when needed.
  - Fails clearly on HTTP/API errors.

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
  Get available servers. Optional zone: `eu` | `na`

---

### Upload

* `upload <file...> [--folder <folderIdOrUrl>] [--zone eu|na] [--server storeX] [--url <uploadUrl>] [--progress] [--json]`

  Notes:

  * Uses the **global upload endpoint** by default.
  * If `--folder` is omitted, the CLI reuses the folder returned by the first upload when uploading multiple files.

* `upload-file <filePath> [folderId] [zoneOrServer]`
  Backwards-compatible wrapper for older usage (prefer `upload` going forward).

---

### Folders & contents

* `create-folder <parentFolderIdOrUrl> [folderName] [--public true|false]` (alias: `mkdir`)
* `ls <folderIdOrUrl> [--json]`
* `get-content <folderIdOrUrl> [--password <pw> | --password-hash <sha256hex>]`
* `search-content <folderIdOrUrl> <searchString> [--password <pw> | --password-hash <sha256hex>]` (alias: `search`)
* `update-content <contentIdOrUrl> <attribute> <newValue>`
* `delete-content <contentIdsCsv>` (alias: `rm`)
* `copy-content <contentsIdCsv> <destFolderIdOrUrl> [--password <pw> | --password-hash <sha256hex>]`
* `move-content <contentsIdCsv> <destFolderIdOrUrl> [--password <pw> | --password-hash <sha256hex>]`
* `import-content <contentsIdCsv> [--password <pw> | --password-hash <sha256hex>]`

> Tip: For most commands you can pass either a **content ID** or a **share URL** like `https://gofile.io/d/AbCdEf`, the CLI extracts the ID automatically.

---

### Direct links

* `create-direct-link <contentIdOrUrl> [expireTime] [sourceIpsAllowedCsv] [domainsAllowedCsv] [authCsv] [domainsBlockedCsv]`
* `update-direct-link <contentIdOrUrl> <directLinkId> [expireTime] [sourceIpsAllowedCsv] [domainsAllowedCsv] [authCsv] [domainsBlockedCsv]`
* `delete-direct-link <contentIdOrUrl> <directLinkId>`

---

### Account

* `get-account-id`
* `get-account <accountId>`
* `whoami`
  Prints account id + root folder id (if available)
* `reset-token <accountId>`
  Invalidates your token and triggers a new one (sent via Gofile email)

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
./gofile.sh upload "./video.mp4" --folder MyFolderId
```

### 5) Legacy-style server selection (optional)

```bash
./gofile.sh upload "./video.mp4" --zone eu
# or:
./gofile.sh upload "./video.mp4" --server store6
```

### 6) List a folder by URL

```bash
./gofile.sh ls https://gofile.io/d/AbCdEf
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
./gofile.sh create-direct-link MyFileId 1704067200 "192.168.1.10" "example.com" "alice:secret" "bad.com"
```

---

## License

MIT License. See [LICENSE](LICENSE).
