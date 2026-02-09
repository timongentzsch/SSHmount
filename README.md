# SSHMount

SSHMount is a macOS menu bar app + FSKit extension + CLI for mounting remote directories over SFTP.

The project is configured to resolve SSH connection details from `~/.ssh/config` host aliases.

## Requirements

- macOS 26+
- Xcode 16+
- Homebrew `libssh2`
- Host aliases in `~/.ssh/config`

Example:

```sshconfig
Host my-server
  HostName 192.168.1.100
  User username
  Port 22
  IdentityFile ~/.ssh/id_ed25519
```

## Architecture

- `App/`: menu bar host app
- `Extension/`: FSKit filesystem extension
- `CLI/`: `sshmount` command-line tool
- `Shared/`: shared models/parsing
- `project.yml`: XcodeGen project definition

## Build

1. Install dependencies:

```bash
brew install libssh2 xcodegen
```

2. Generate Xcode project:

```bash
xcodegen generate
```

3. Open and build:

```bash
open SSHMount.xcodeproj
```

Or build from terminal:

```bash
xcodebuild -project SSHMount.xcodeproj -scheme SSHMount -configuration Debug -derivedDataPath .derivedData build
```

## Development

### FSKit Daemon Issues

During development, FSKit can be unstable and may leave the extension in a dangling state (e.g., "Resource busy" errors after failed mounts). If you encounter issues after reinstalling the extension, restart the FSKit daemons:

```bash
sudo pkill -9 fskitd && pkill -9 fskit_agent
```

This kills both:
- `fskitd` (system daemon, needs sudo) - clears cached resource state
- `fskit_agent` (per-user daemon) - handles user-level operations

`launchd` will automatically respawn both daemons. This is often necessary when testing mount/unmount cycles.

## Usage

### App

Create a mount from:
- `Host` (must exist in `~/.ssh/config`)
- `Remote Path`
- optional `Mount Options`

The app automatically tries SSH key authentication first. If keys fail, you'll be prompted for a password (used only for that mount attempt, never saved).

### CLI

Commands:

```bash
sshmount mount <hostAlias>:<remotePath> <localMountPoint> -o <mountOptions>
sshmount unmount <localMountPoint>
sshmount list
sshmount status
sshmount test <hostAlias>:<remotePath>
```

Example:

```bash
sshmount mount my-server:~/project ~/Volumes/my-server -o rdonly,nosuid,follow_symlinks=no
```

Unmount:

```bash
sshmount unmount ~/Volumes/my-server
```

## Supported mount options

- `ro` / `rdonly`
- `uid=<n>`
- `gid=<n>`
- `umask=<octal>`
- `noexec`
- `nosuid`
- `noatime`
- `cache_timeout=<seconds>`
- `dir_cache_timeout=<seconds>`
- `follow_symlinks=yes|no`
- `reconnect_max=<n>`
- `reconnect_timeout=<seconds>`
- `parallel_sessions=<n>` (1-8, default 1; enables parallel read sessions)
- `parallel_write_sessions=<n>` (1-8, default 1; enables parallel write sessions, path-sticky to preserve per-file ordering)
- `nonblocking_io=yes|no` (default yes; enables non-blocking SFTP read/write loops on dedicated I/O sessions)

Notes:
- `nodev` is explicitly unsupported.
- SSH connection/auth options should be configured in `~/.ssh/config`.
- If `parallel_write_sessions` is set, writes are distributed by path (same file stays ordered).
- The app tries SSH key authentication first; password prompt appears only if key auth fails. Passwords are never saved.

## Throughput Tuning

Recommended starting point for high-throughput links:

```bash
-o nonblocking_io=yes,parallel_sessions=4,parallel_write_sessions=4,cache_timeout=5,dir_cache_timeout=5
```

Tune `parallel_sessions` and `parallel_write_sessions` based on workload and server capacity.
Too many sessions can reduce performance on constrained servers.

## Important note about Git over SSHFS

For repositories mounted over SFTP/SSHFS, Git metadata writes can be unreliable depending on server/filesystem behavior.

For best reliability, run Git write operations directly on the server:

```bash
ssh <hostAlias> 'cd /path/to/repo && git status'
```
