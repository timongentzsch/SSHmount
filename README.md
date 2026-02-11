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
Before daemon restarts, try force unmount first (`sshmount unmount --force <mountPoint>` or the app's Force unmount action).

## Usage

### App

Create a mount from:
- `Host` (must exist in `~/.ssh/config`)
- `Remote Path`
- typed `Connection Options` (profile, workers, health, queue timeout, cache)

The app automatically tries SSH key authentication first. If keys fail, you'll be prompted for a password (used only for that mount attempt, never saved).
If a mount is stuck, use the row's **Force unmount** action (filled eject icon), which runs `umount -f`.

### CLI

Commands:

```bash
sshmount mount <hostAlias>:<remotePath> <localMountPoint> \
  --profile <standard|git> \
  --read-workers <1-8> \
  --write-workers <1-8> \
  --io-mode <blocking|nonblocking> \
  --health-interval <1-300> \
  --health-timeout <1-120> \
  --health-failures <1-12> \
  --busy-threshold <1-4096> \
  --grace-seconds <0-300> \
  --queue-timeout-ms <100-60000> \
  --cache-attr <0-300> \
  --cache-dir <0-300>
sshmount unmount <localMountPoint>
sshmount unmount --force <localMountPoint>
sshmount list
sshmount status
sshmount test <hostAlias>:<remotePath>
```

Example:

```bash
sshmount mount my-server:~/project ~/Volumes/my-server \
  --profile standard \
  --read-workers 1 \
  --write-workers 1 \
  --io-mode blocking \
  --health-interval 5 \
  --health-timeout 10 \
  --health-failures 5 \
  --busy-threshold 32 \
  --grace-seconds 20 \
  --queue-timeout-ms 2000 \
  --cache-attr 5 \
  --cache-dir 5
```

Unmount:

```bash
sshmount unmount ~/Volumes/my-server
sshmount unmount --force ~/Volumes/my-server
```

## Canonical options

Only canonical typed options are supported:
- `profile`
- `read_workers`
- `write_workers`
- `io_mode`
- `health_interval_s`
- `health_timeout_s`
- `health_failures`
- `busy_threshold`
- `grace_seconds`
- `queue_timeout_ms`
- `cache_attr_s`
- `cache_dir_s`

Legacy comma-separated mount option syntax is intentionally unsupported.

## Throughput Tuning

Recommended starting point for stable links:

```bash
--profile standard --read-workers 1 --write-workers 1 --io-mode blocking --health-interval 5 --health-timeout 10 --health-failures 5 --busy-threshold 32 --grace-seconds 20 --queue-timeout-ms 2000 --cache-attr 5 --cache-dir 5
```

For Git-heavy workflows:

```bash
--profile git
```

## Important note about Git over SSHFS

For repositories mounted over SFTP/SSHFS, Git metadata writes can be unreliable depending on server/filesystem behavior.

For best reliability, run Git write operations directly on the server:

```bash
ssh <hostAlias> 'cd /path/to/repo && git status'
```
