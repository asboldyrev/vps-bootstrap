#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
[[ $EUID -eq 0 ]] || { echo "Requires root/sudo" >&2; exit 1; }
MODE=${1:?Expected prepare|secure|confirm}
CFG=${2:?Expected configuration path}
[[ -f "$CFG" ]] || exit 1
# This file is produced locally with Bash %q escaping, and never from untrusted input.
source "$CFG"
[[ "$ADMIN" =~ ^[a-z_][a-z0-9_-]{0,30}$ && "$ADMIN" != root ]] || exit 1
[[ "$OLDPORT" =~ ^[0-9]+$ && "$NEWPORT" =~ ^[0-9]+$ ]] || exit 1
mkdir -p /var/lib/vps-bootstrap; chmod 700 /var/lib/vps-bootstrap
log() { echo "[vps-bootstrap] $*"; }
install_packages() {
 export DEBIAN_FRONTEND=noninteractive
 apt-get update
 apt-get -y upgrade
 apt-get install -y sudo curl ca-certificates git nano htop ufw openssh-server unattended-upgrades fail2ban
}
case "$MODE" in
prepare)
 . /etc/os-release
 [[ "$ID" == ubuntu || "$ID" == debian ]] || { echo "Only Debian/Ubuntu supported" >&2; exit 1; }
 install_packages
 if ! id "$ADMIN" >/dev/null 2>&1; then useradd -m -s /bin/bash "$ADMIN"; fi
 usermod -aG sudo "$ADMIN"
 HOME_DIR=$(getent passwd "$ADMIN" | cut -d: -f6)
 install -d -m 700 -o "$ADMIN" -g "$ADMIN" "$HOME_DIR/.ssh"
 touch "$HOME_DIR/.ssh/authorized_keys"
 chmod 600 "$HOME_DIR/.ssh/authorized_keys"; chown "$ADMIN:$ADMIN" "$HOME_DIR/.ssh/authorized_keys"
 grep -qxF "$KEY" "$HOME_DIR/.ssh/authorized_keys" || printf '%s\n' "$KEY" >> "$HOME_DIR/.ssh/authorized_keys"
 if ((NOPASS)); then
   printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$ADMIN" >"/etc/sudoers.d/90-vps-bootstrap"
   chmod 440 /etc/sudoers.d/90-vps-bootstrap
 else
   rm -f /etc/sudoers.d/90-vps-bootstrap
   echo "Set a password for $ADMIN, required for sudo:"
   passwd "$ADMIN"
 fi
 visudo -cf /etc/sudoers >/dev/null
 log "Preparation done. Verify new SSH key and sudo from local computer."
;;
secure)
 # Both ports are opened before applying any potentially disruptive SSH changes.
 ufw allow "${OLDPORT}/tcp"
 ufw allow "${NEWPORT}/tcp"
 if [[ -n "$EXTRAS" ]]; then
   for p in $EXTRAS; do ufw allow "$p"; done
 fi
 ufw default deny incoming
 ufw default allow outgoing
 ufw --force enable
 if [[ -f /etc/ssh/sshd_config ]]; then cp -a /etc/ssh/sshd_config /var/lib/vps-bootstrap/sshd_config.bak; fi
 [[ -d /etc/ssh/sshd_config.d ]] || mkdir -p /etc/ssh/sshd_config.d
 [[ ! -f /etc/ssh/sshd_config.d/00-vps-bootstrap.conf ]] || cp -a /etc/ssh/sshd_config.d/00-vps-bootstrap.conf /var/lib/vps-bootstrap/ssh-dropin.bak
 cp -a /etc/ssh/sshd_config /var/lib/vps-bootstrap/sshd_config.before
 if systemctl is-active --quiet ssh.socket; then
   SSH_ACTIVATION=socket
 elif systemctl is-active --quiet ssh.service; then
   SSH_ACTIVATION=service
 else
   log "No active SSH socket or service; aborting"
   exit 1
 fi
 printf "%s\n" "$SSH_ACTIVATION" >/var/lib/vps-bootstrap/ssh-activation.before
 printf "%s\n" "$OLDPORT" >/var/lib/vps-bootstrap/old-port.before
 cat >/var/lib/vps-bootstrap/rollback.sh <<'ROLLBACK'
#!/bin/bash
set -e
[ ! -f /var/lib/vps-bootstrap/sshd_config.before ] || cp -a /var/lib/vps-bootstrap/sshd_config.before /etc/ssh/sshd_config
if [ -f /var/lib/vps-bootstrap/ssh-dropin.bak ]; then
 cp -a /var/lib/vps-bootstrap/ssh-dropin.bak /etc/ssh/sshd_config.d/00-vps-bootstrap.conf
else
 rm -f /etc/ssh/sshd_config.d/00-vps-bootstrap.conf
fi
/usr/sbin/sshd -t
systemctl daemon-reload
case "$(cat /var/lib/vps-bootstrap/ssh-activation.before)" in
 socket) systemctl restart ssh.socket ;;
 service) systemctl restart ssh.service ;;
esac
ufw allow "$(cat /var/lib/vps-bootstrap/old-port.before)/tcp"
ROLLBACK
 chmod 700 /var/lib/vps-bootstrap/rollback.sh
 systemd-run --unit=vps-bootstrap-rollback --on-active=10m /bin/bash /var/lib/vps-bootstrap/rollback.sh
 # Include the managed file first, so OpenSSH first-value-wins rules work.
 sed -i '/^[[:space:]]*Include[[:space:]]*\/etc\/ssh\/sshd_config.d\/\*.conf/d' /etc/ssh/sshd_config
 sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
 printf 'Port %s\nPermitRootLogin no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPubkeyAuthentication yes\n' "$NEWPORT" >/etc/ssh/sshd_config.d/00-vps-bootstrap.conf
 /usr/sbin/sshd -t || { bash /var/lib/vps-bootstrap/rollback.sh; exit 1; }
 # Preserve Ubuntu 24.04 socket activation; do not switch to ssh.service.
 if [[ "$SSH_ACTIVATION" == socket ]]; then
   if ! systemctl daemon-reload || ! systemctl restart ssh.socket || ! systemctl is-active --quiet ssh.socket; then
     log "Socket reload failed; restoring original SSH configuration"
     bash /var/lib/vps-bootstrap/rollback.sh || true
     exit 1
   fi
 else
   if ! systemctl restart ssh.service || ! systemctl is-active --quiet ssh.service; then
     log "SSH service failed; restoring original configuration"
     bash /var/lib/vps-bootstrap/rollback.sh || true
     exit 1
   fi
 fi
 # Confirm effective settings, not just syntax.
 EFFECTIVE=$(/usr/sbin/sshd -T)
 grep -qx "port $NEWPORT" <<<"$EFFECTIVE" || { bash /var/lib/vps-bootstrap/rollback.sh; exit 1; }
 grep -qx 'permitrootlogin no' <<<"$EFFECTIVE" || { bash /var/lib/vps-bootstrap/rollback.sh; exit 1; }
 grep -qx 'passwordauthentication no' <<<"$EFFECTIVE" || { bash /var/lib/vps-bootstrap/rollback.sh; exit 1; }
 grep -qx 'kbdinteractiveauthentication no' <<<"$EFFECTIVE" || { bash /var/lib/vps-bootstrap/rollback.sh; exit 1; }
 install -m 700 "$0" /var/lib/vps-bootstrap/remote.sh
 install -m 600 "$CFG" /var/lib/vps-bootstrap/config.env
 # Configure automatic security updates without automatic reboot.
 cat >/etc/apt/apt.conf.d/52-vps-bootstrap <<'APT'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
Unattended-Upgrade::Automatic-Reboot "false";
APT
 systemctl enable --now apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
 cat >/etc/fail2ban/jail.d/vps-bootstrap.local <<'F2B'
[sshd]
enabled = true
backend = systemd
F2B
 systemctl enable --now fail2ban || true
 systemctl restart fail2ban || true
 if ((DOCKER)); then
   . /etc/os-release
   install -d -m 0755 /etc/apt/keyrings
   curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc
   chmod a+r /etc/apt/keyrings/docker.asc
   ARCH=$(dpkg --print-architecture)
   CODENAME=${VERSION_CODENAME:?}
   printf 'Types: deb\nURIs: https://download.docker.com/linux/%s\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: /etc/apt/keyrings/docker.asc\n' "$ID" "$CODENAME" "$ARCH" >/etc/apt/sources.list.d/docker.sources
   apt-get update
   apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
   systemctl enable --now docker
 fi
 log "Hardening applied. Rollback in 10 min unless confirmed."
;;
confirm)
 systemctl stop vps-bootstrap-rollback.timer 2>/dev/null || true
 systemctl stop vps-bootstrap-rollback.service 2>/dev/null || true
 systemctl reset-failed vps-bootstrap-rollback.service 2>/dev/null || true
 if [[ "$OLDPORT" != "$NEWPORT" && " $EXTRAS " != *" $OLDPORT/tcp "* ]]; then ufw --force delete allow "${OLDPORT}/tcp" || true; fi
 log "Verified state:"
 id "$ADMIN"
 /usr/sbin/sshd -T | grep -E '^(port|permitrootlogin|passwordauthentication|kbdinteractiveauthentication) '
 ufw status verbose
 systemctl is-active fail2ban || true
 timedatectl show -p NTPSynchronized --value || true
 systemctl is-active docker 2>/dev/null || true
 [[ ! -f /var/run/reboot-required ]] || log "Reboot recommended (not automatic)"
 log "Configuration complete."
;;
*) echo "Unknown mode" >&2; exit 1 ;;
esac
