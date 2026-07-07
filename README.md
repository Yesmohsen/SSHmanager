# SSH Manager

Manage SSH keys and password authentication on Ubuntu with a single script.

```bash
curl -sSL https://raw.githubusercontent.com/Yesmohsen/SSHmanager/main/ssh-manager.sh -o ssh-manager.sh && chmod +x ssh-manager.sh && sudo ./ssh-manager.sh
```

## Features

| # | Option | Description |
|---|--------|-------------|
| 1 | **Add SSH Public Key** | Append a public key to `~/.ssh/authorized_keys` with correct permissions |
| 2 | **Import SSH Private Key** | Copy a private key to `~/.ssh/` and set `600` permissions |
| 3 | **Disable Password Authentication** | Set `PasswordAuthentication no` in `/etc/ssh/sshd_config` and restart SSH |
| 4 | **Enable & Reset Login Password** | Re-enable password auth in SSH and set a new user password |
| 5 | **Add Key + Disable Password** | Lock down to key-only access in one step |
| 6 | **Remove Key + Enable Password** | Remove a selected public key and re-enable password auth |
| 7 | **Remove Key + Enable PW + Reset** | Full rollback: remove key, enable password, and reset password |

## Usage

### Interactive Menu

```bash
./ssh-manager.sh
```

### Command Line

```bash
./ssh-manager.sh --add-key ~/.ssh/id_ed25519.pub
./ssh-manager.sh --import-key ~/downloaded_private_key
./ssh-manager.sh --list-keys
./ssh-manager.sh --remove-key <index>
./ssh-manager.sh --disable-password
./ssh-manager.sh --enable-password
./ssh-manager.sh --reset-password
./ssh-manager.sh --help
```

## How It Works

- **Key operations** (options 1-2) need no sudo — they only touch `~/.ssh/`
- **System operations** (options 3-7) modify `/etc/ssh/sshd_config` and require sudo
- **Backups**: `sshd_config` is backed up to `~/.ssh-manager/backups/` before any change
- **Duplicate prevention**: public keys already in `authorized_keys` are detected and skipped
- **Safety**: destructive operations prompt for confirmation before proceeding

## Requirements

- Ubuntu (or any Debian-based distro with OpenSSH server)
- `bash`, `sudo`, `systemctl` / `service`
