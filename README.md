# VPS Bootstrap v1.0 (draft)

Interactive **local** Bash bootstrap for newly created Debian/Ubuntu VPS. Runs on a Linux workstation (e.g. Linux Mint), connects over SSH, and needs neither cloud-init nor Ansible.

> **Unverified on real VPS.** Bash source should be reviewed and tested on a disposable instance with provider console access before any production use. It changes remote SSH, firewall, packages, users and optionally Docker.

## Quick start

```bash
git clone https://github.com/asboldyrev/vps-bootstrap.git
cd vps-bootstrap
chmod +x bootstrap.sh
./bootstrap.sh
```

Requirements: local `bash`, `ssh`, `scp`, `ssh-keygen`; initial root SSH access (or an existing sudo-enabled user), a local SSH key pair (`~/.ssh/id_ed25519{,.pub}` by default), and a Debian/Ubuntu VPS with systemd and apt. Generate an SSH key if needed:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519
```

**Never send your private key to the VPS.** Only the public key is installed. If the initial SSH user is not root, the script expects working `sudo` privileges.

The launcher asks for VPS address, current SSH user and port, new administrator name, public-key path, passworded or passwordless sudo, new SSH port, extra UFW ports (e.g. `80/tcp 443/tcp 51820/udp`), Docker/Compose installation and local SSH alias.

## Workflow

1. Connect to the original SSH account and stage a temporary worker.
2. Update apt packages; install base tools (sudo, curl, ca-certificates, git, nano, htop, UFW, OpenSSH, unattended-upgrades and Fail2ban); create administrator, sudo policy and authorized key.
3. Independently confirm SSH public-key login and sudo before changing SSH security.
4. Open original/new SSH ports in UFW, then install SSH hardening: no root SSH, no password/keyboard-interactive authentication, optional custom SSH port. Validate `sshd` settings. A systemd rollback timer restores the previous SSH configuration in approximately 10 minutes if not confirmed.
5. Enable automatic updates (no automatic reboot) and Fail2ban; optionally install Docker Engine, Buildx and Compose Plugin from Docker's official repository.
6. Independently verify login and sudo on the new port, cancel the rollback timer, show diagnostics, and optionally write a local `~/.ssh/config` alias.

Reboots are not automatic. No hostname, timezone or swap changes. The configuration should be rerunnable on **fresh** VPS instances, but is not guaranteed to preserve all pre-existing custom SSH, UFW or Docker setups.

## SSH and firewall safety

- Always keep your provider's serial/web console available, especially if changing SSH ports.
- If your provider uses its own cloud firewall, allow the new TCP SSH port **before** running the tool.
- If the new port cannot be reached, do **not** close the original session. The server-side SSH rollback timer should restore the former SSH config after approximately 10 minutes. If necessary, use the provider console to run `sudo bash /var/lib/vps-bootstrap/rollback.sh`.
- Existing `~/.ssh/config` Host entries are not intentionally overwritten.
- **Docker warning:** Published Docker ports may bypass normal UFW filtering. Bind private services to `127.0.0.1` or apply appropriate Docker-aware firewall rules. The new user is not automatically added to the privileged `docker` group.
- The `sudo` password mode asks you to set a new administrator password interactively.
- `unattended-upgrades` uses the OS distro's configured allowed origins; inspect the distribution config if you require *only* security origins.

## Limitations and verification

This project is intended for clean Debian/Ubuntu VPS, not production hosts with custom firewall or SSH setups. There is no external CI, end-to-end VM test or provider-specific compatibility certification yet. A failed package install or Docker installation can leave a partially configured machine; use a fresh disposable VM for the first test.

Useful manual diagnostics on the VPS:

```bash
sudo sshd -t
sudo sshd -T | grep -E '^(port|permitrootlogin|passwordauthentication|kbdinteractiveauthentication)'
sudo ufw status verbose
sudo fail2ban-client status sshd
sudo systemctl status ssh.service
sudo docker compose version   # only if Docker was selected
```

Documentation: [OpenSSH (Ubuntu)](https://ubuntu.com/server/docs/how-to/security/openssh-server/), [automatic updates](https://ubuntu.com/server/docs/how-to/software/automatic-updates/), [Docker install](https://docs.docker.com/engine/install/ubuntu/), [Docker firewall considerations](https://docs.docker.com/engine/network/packet-filtering-firewalls/).
