## Gofile CLI

This repository contains a **Bash CLI script** (`gofile.sh`) that interacts with the [Gofile.io API](https://gofile.io). It allows you to upload files, create folders, update content, manage direct links, and more—all from the command line.  

---

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [Usage](#usage)
  - [Commands](#commands)
  - [Examples](#examples)
- [License](#license)

---

## Features

- **Store and manage your Gofile API Token**:  
  Easily save your token in a config file (`~/.config/gofile-cli/config`) without hardcoding it.

- **Upload files**:  
  Upload any file to Gofile, either to a new public folder or to an existing folder in your account.

- **Create and manage folders**:  
  Create subfolders in your Gofile account, set folder attributes (name, public, expiry date, etc.).

- **Retrieve account and folder info**:  
  Fetch details about your account, list contents of folders, and manage them from the CLI.

- **Search**:  
  Search for files/folders by name or tags within a specified folder.

- **Direct links**:  
  Create/update/delete direct links for files or folders ( ZIP for folder downloads ) with optional password protection, IP/domain restrictions, and expiry times.

- **Copy, move, and import content**:  
  Restructure your Gofile account contents by copying/moving to different folders—or import public content into your own root.

- **Reset your token**:  
  Invalidate your current token and receive a new one if necessary.

---

## Requirements

1. **Bash** (tested on Linux; Windows under WSL should also work).
2. [**curl**](https://curl.se/) for making HTTP requests.
3. [**jq**](https://stedolan.github.io/jq/) for parsing JSON in the script.

---

## Installation

1. **Clone** this repository:
   ```bash
   git clone https://github.com/Ognisty321/gofile-cli.git (or your username if forked)
   cd gofile-cli
   ```

2. **Make the script executable**:
   ```bash
   chmod +x gofile.sh
   ```

3. **(Optional)** Copy or symlink `gofile.sh` to a directory in your `PATH`:
   ```bash
   sudo cp gofile.sh /usr/local/bin/gofile
   # Or create a symlink:
   # ln -s /path/to/gofile.sh /usr/local/bin/gofile
   ```

Now you can run `./gofile.sh` (or just `gofile` if it’s in your `PATH`).

---

## Configuration

1. **Set your Gofile.io API Token**:
   ```bash
   ./gofile.sh set-token <YOUR_API_TOKEN>
   ```
   This creates (or updates) a config file in `~/.config/gofile-cli/config`:
   ```
   API_TOKEN=abc123def456
   ```

2. **Verify** that your token is stored:
   ```bash
   ./gofile.sh show-token
   ```

---

## Usage

```plaintext
Usage: ./gofile.sh <command> [arguments]

Commands:
  set-token <TOKEN>            
      Save your Gofile.io API token to config

  show-token                   
      Print the currently stored API token

  get-servers [zone]          
      Get available servers. Optional zone: eu | na

  upload-file <filePath> [folderId] [zoneOrServer]
      Upload a file. 
      - folderId: (optional) the folder ID to upload into.
      - zoneOrServer: (optional) either "eu" or "na" for zone selection, or "storeX" for a specific server.

  create-folder <parentFolderId> [folderName]
      Create a new folder in parentFolderId (folderName optional)

  update-content <contentId> <attribute> <newValue>
      Update content attributes: name, description, tags, public, expiry, password

  delete-content <contentIds>
      Permanently delete files/folders by comma-separated IDs

  get-content <contentId>
      Retrieve detailed info about a folder (only works with folder IDs)

  search-content <folderId> <searchString>
      Search files/folders by name/tags recursively under the specified folder

  create-direct-link <contentId> [expireTime] [sourceIpsAllowed] [domainsAllowed] [auth]
      Create a direct link (for files/folders). 
      - expireTime: Unix timestamp
      - sourceIpsAllowed: comma-separated IPs
      - domainsAllowed: comma-separated domains
      - auth: comma-separated "user:pass" pairs

  update-direct-link <contentId> <directLinkId> [expireTime] [sourceIpsAllowed] [domainsAllowed] [auth]
      Update an existing direct link’s settings

  delete-direct-link <contentId> <directLinkId>
      Delete a direct link permanently

  copy-content <contentsId> <destFolderId>
      Copy multiple files/folders (comma-separated) to a new folder

  move-content <contentsId> <destFolderId>
      Move multiple files/folders (comma-separated) to a new folder

  import-content <contentsId>
      Import public content (comma-separated) to your root folder

  get-account-id
      Retrieve the account ID associated with your current token

  get-account <accountId>
      Retrieve detailed info about the specified account

  reset-token <accountId>
      Reset your current token. You’ll receive a new token via email.
```

---

### Commands

#### 1. **set-token**

- **Usage**:
  ```bash
  ./gofile.sh set-token <YOUR_API_TOKEN>
  ```
- **Description**: Writes your API token to `~/.config/gofile-cli/config`.

#### 2. **show-token**

- **Usage**:
  ```bash
  ./gofile.sh show-token
  ```
- **Description**: Displays the currently stored token (if any).

#### 3. **get-servers**

- **Usage**:
  ```bash
  # All servers (no zone filter)
  ./gofile.sh get-servers

  # Only servers in 'eu' zone
  ./gofile.sh get-servers eu

  # Only servers in 'na' zone (may return empty if none exist)
  ./gofile.sh get-servers na
  ```
- **Description**: Retrieves a list of servers. If a zone is specified, the script will post-process the response to filter servers in that zone only.  
- **Note**: Gofile might fall back to other zones if none match the requested zone.

#### 4. **upload-file**

- **Usage**:
  ```bash
  ./gofile.sh upload-file <filePath> [folderId] [zoneOrServer]
  ```
  - **filePath**: Local path to the file you want to upload.
  - **folderId** (optional): If omitted, your file uploads to a new public folder (guest mode or your default account root, depending on token).
  - **zoneOrServer** (optional): 
    - `eu` or `na` to automatically pick the first server from that zone. 
    - Or specify a server name directly, e.g. `store6`.

- **Examples**:
  ```bash
  # Upload a file to your default zone
  ./gofile.sh upload-file "/path/to/video.mp4"

  # Upload to a specific folderId in the 'eu' zone
  ./gofile.sh upload-file "/path/to/video.mp4" MyFolderId eu

  # Upload to a folder using a specific server
  ./gofile.sh upload-file "/path/to/video.mp4" MyFolderId store6
  ```

#### 5. **create-folder**

- **Usage**:
  ```bash
  ./gofile.sh create-folder <parentFolderId> [folderName]
  ```
- **Description**: Creates a subfolder in the specified `parentFolderId`. If `folderName` is omitted, Gofile auto-generates a folder name.

#### 6. **update-content**

- **Usage**:
  ```bash
  ./gofile.sh update-content <contentId> <attribute> <newValue>
  ```
- **Attributes**:
  - `name`: Rename file/folder.
  - `description`: Change folder description.
  - `tags`: Comma-separated tags.
  - `public`: `"true"` or `"false"` (folders only).
  - `expiry`: Unix timestamp (folders only).
  - `password`: String password (folders only).

#### 7. **delete-content**

- **Usage**:
  ```bash
  ./gofile.sh delete-content <contentIds>
  ```
- **Description**: Permanently delete one or more files/folders by passing comma-separated IDs.

#### 8. **get-content**

- **Usage**:
  ```bash
  ./gofile.sh get-content <folderId>
  ```
- **Description**: Retrieves detailed info for a folder and its contents (files/subfolders).

#### 9. **search-content**

- **Usage**:
  ```bash
  ./gofile.sh search-content <folderId> <searchString>
  ```
- **Description**: Recursively searches in `folderId` for files/folders matching `searchString` in name or tags.

#### 10. **create-direct-link**

- **Usage**:
  ```bash
  ./gofile.sh create-direct-link <contentId> [expireTime] [sourceIpsAllowed] [domainsAllowed] [auth]
  ```
- **Description**: Creates a direct access link to a file/folder.  
  - `expireTime`: Unix timestamp (optional).  
  - `sourceIpsAllowed`: Comma-separated IPs (optional).  
  - `domainsAllowed`: Comma-separated domains (optional).  
  - `auth`: Comma-separated `user:pass` pairs (optional).

#### 11. **update-direct-link**

- **Usage**:
  ```bash
  ./gofile.sh update-direct-link <contentId> <directLinkId> [expireTime] [sourceIpsAllowed] [domainsAllowed] [auth]
  ```
- **Description**: Updates an existing direct link’s configuration.

#### 12. **delete-direct-link**

- **Usage**:
  ```bash
  ./gofile.sh delete-direct-link <contentId> <directLinkId>
  ```
- **Description**: Permanently removes a direct link without deleting the underlying content.

#### 13. **copy-content**

- **Usage**:
  ```bash
  ./gofile.sh copy-content <contentsId> <destFolderId>
  ```
- **Description**: Copies multiple files/folders (comma-separated) to another folder.

#### 14. **move-content**

- **Usage**:
  ```bash
  ./gofile.sh move-content <contentsId> <destFolderId>
  ```
- **Description**: Moves multiple files/folders to another folder.

#### 15. **import-content**

- **Usage**:
  ```bash
  ./gofile.sh import-content <contentsId>
  ```
- **Description**: Imports **public** content (by ID) into your account’s root folder.

#### 16. **get-account-id**

- **Usage**:
  ```bash
  ./gofile.sh get-account-id
  ```
- **Description**: Retrieves the **account ID** associated with your current token.

#### 17. **get-account**

- **Usage**:
  ```bash
  ./gofile.sh get-account <accountId>
  ```
- **Description**: Retrieves detailed information about a specific account ID.

#### 18. **reset-token**

- **Usage**:
  ```bash
  ./gofile.sh reset-token <accountId>
  ```
- **Description**: Immediately **invalidates** your current token and sends a new token to your Gofile-registered email.

---

## Examples

1. **Set your token and verify**:
   ```bash
   ./gofile.sh set-token abc123def456
   ./gofile.sh show-token
   ```

2. **Get servers (all, eu, or na)**:
   ```bash
   ./gofile.sh get-servers       # Show all possible servers
   ./gofile.sh get-servers eu    # Show EU servers only
   ./gofile.sh get-servers na    # Show NA servers only (might be empty)
   ```

3. **Upload a file**:
   ```bash
   # Default server pick:
   ./gofile.sh upload-file "/path/to/myvideo.mp4"

   # Specify folder and zone:
   ./gofile.sh upload-file "/path/to/myvideo.mp4" MyFolderId eu

   # Specify folder and direct server name:
   ./gofile.sh upload-file "/path/to/myvideo.mp4" MyFolderId store6
   ```

4. **Create a folder**:
   ```bash
   ./gofile.sh create-folder rootFolderId "My New Folder"
   ```

5. **Update content (rename folder)**:
   ```bash
   ./gofile.sh update-content myFolderId name "Super Cool Folder"
   ```

6. **Delete content**:
   ```bash
   ./gofile.sh delete-content fileId1,fileId2
   ```

7. **Get folder details**:
   ```bash
   ./gofile.sh get-content myFolderId
   ```

8. **Search**:
   ```bash
   ./gofile.sh search-content myFolderId "music"
   ```

9. **Create a direct link**:
   ```bash
   ./gofile.sh create-direct-link myFileId 1704067200 "192.168.1.10" "example.com" "alice:secret"
   ```

10. **Copy content**:
    ```bash
    ./gofile.sh copy-content fileId1,fileId2 destinationFolderId
    ```

11. **Move content**:
    ```bash
    ./gofile.sh move-content folderId1,fileId99 anotherFolderId
    ```

12. **Import content**:
    ```bash
    ./gofile.sh import-content publicFileId1,publicFolderId2
    ```

13. **Get account ID**:
    ```bash
    ./gofile.sh get-account-id
    ```

14. **Reset token**:
    ```bash
    ./gofile.sh reset-token 12345
    ```

---

## License

This project is released under the [MIT License](LICENSE). Feel free to modify and distribute as needed. Contributions are welcome!
