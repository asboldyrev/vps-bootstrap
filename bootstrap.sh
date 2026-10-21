#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$HERE/remote.sh" ]] || { echo "Missing remote.sh" >&2; exit 1; }
for c in ssh scp ssh-keygen mktemp; do command -v "$c" >/dev/null || { echo "Missing: $c" >&2; exit 1; }; done
[[ -t 0 ]] || { echo "Run interactively in a terminal" >&2; exit 1; }
ask() { local v; read -r -p "$2 [$3]: " v; printf -v "$1" '%s' "${v:-$3}"; }
yes() { local a; read -r -p "$1 [y/N]: " a; [[ "$a" =~ ^([yY]|yes|да|д)$ ]]; }
port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1>=1 && 10#$1<=65535 )); }
die() { echo "ERROR: $*" >&2; exit 1; }
echo "VPS Bootstrap 1.0 — Debian/Ubuntu, local SSH launcher"
ask HOST "VPS IP or DNS" ""
[[ "$HOST" =~ ^[a-zA-Z0-9.:-]+$ && "$HOST" != -* ]] || die "Invalid host"
ask LOGIN "Current SSH login" root
[[ "$LOGIN" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid login"
ask OLDPORT "Current SSH port" 22; port "$OLDPORT" || die "Invalid port"
ask ADMIN "New administrator name" admin
[[ "$ADMIN" =~ ^[a-z_][a-z0-9_-]{0,30}$ && "$ADMIN" != root ]] || die "Invalid administrator"
ask PUB "Public SSH key (.pub)" "$HOME/.ssh/id_ed25519.pub"
PUB="${PUB/#\~/$HOME}"
[[ "$PUB" == *.pub && -r "$PUB" && -r "${PUB%.pub}" ]] || die "A readable public/private SSH key pair is required"
ssh-keygen -lf "$PUB" >/dev/null || die "Invalid public key"
KEY=$(<"$PUB")
[[ "$KEY" != *$'\n'* && "$KEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-[^[:space:]]+)[[:space:]] ]] || die "Expected one SSH public key"
PRIV="${PUB%.pub}"
KEY_ID=$(awk '{print $2}' <<< "$KEY")
PRIVATE_KEY_ID=$(ssh-keygen -y -f "$PRIV" | awk '{print $2}') || die "Could not read private key"
[[ "$KEY_ID" == "$PRIVATE_KEY_ID" ]] || die "Public/private key mismatch"
if yes "Passwordless sudo?"; then NOPASS=1; else NOPASS=0; fi
ask NEWPORT "New SSH port" "$OLDPORT"; port "$NEWPORT" || die "Invalid new port"
ask EXTRAS "Extra UFW ports (e.g. 80/tcp 443/tcp 51820/udp)" ""
for rule in $EXTRAS; do
  [[ "$rule" =~ ^([0-9]{1,5})(:([0-9]{1,5}))?/(tcp|udp)$ ]] || die "Invalid UFW rule: $rule"
  port "${BASH_REMATCH[1]}" && port "${BASH_REMATCH[3]:-${BASH_REMATCH[1]}}" || die "Invalid UFW port"
done
if yes "Install Docker Engine and Compose plugin?"; then DOCKER=1; else DOCKER=0; fi
if yes "Add local SSH alias?"; then
  ask ALIAS "SSH alias" "vps-${HOST//[.:]/-}"
  [[ "$ALIAS" =~ ^[a-zA-Z][a-zA-Z0-9._-]*$ ]] || die "Invalid alias"
else ALIAS=""; fi
printf '\nTarget: %s@%s:%s -> %s@%s:%s\nUFW: %s\nDocker: %s\n' "$LOGIN" "$HOST" "$OLDPORT" "$ADMIN" "$HOST" "$NEWPORT" "$EXTRAS" "$DOCKER"
echo "IMPORTANT: have access to the provider console and open the new SSH port in the provider firewall."
yes "Proceed with potentially disruptive changes?" || exit 0
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
CONF="$TMP/config.env"
printf 'ADMIN=%q\nOLDPORT=%q\nNEWPORT=%q\nNOPASS=%q\nEXTRAS=%q\nDOCKER=%q\nKEY=%q\n' "$ADMIN" "$OLDPORT" "$NEWPORT" "$NOPASS" "$EXTRAS" "$DOCKER" "$KEY" >"$CONF"
TARGET="$LOGIN@$HOST"
SSH=(-p "$OLDPORT" -o StrictHostKeyChecking=ask)
SCP_HOST="$HOST"; [[ "$HOST" != *:* ]] || SCP_HOST="[$HOST]"
ssh "${SSH[@]}" "$TARGET" "true" || die "Initial SSH connection failed"
RDIR=$(ssh "${SSH[@]}" "$TARGET" 'mktemp -d /tmp/vps-bootstrap.XXXXXXXX') || die "Cannot prepare remote directory"
[[ "$RDIR" =~ ^/tmp/vps-bootstrap\.[[:alnum:]]+$ ]] || die "Invalid remote directory"
scp -P "$OLDPORT" "$HERE/remote.sh" "$CONF" "$LOGIN@$SCP_HOST:$RDIR/" || die "SCP failed"
RUN="bash '$RDIR/remote.sh'"; [[ "$LOGIN" == root ]] || RUN="sudo $RUN"
ssh -tt "${SSH[@]}" "$TARGET" "$RUN prepare '$RDIR/config.env'" || die "Prepare failed: original SSH remains enabled"
CHECK=(-i "$PRIV" -o IdentitiesOnly=yes -o PreferredAuthentications=publickey -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o ControlMaster=no -o ConnectTimeout=12)
test "$(ssh "${CHECK[@]}" -p "$OLDPORT" "$ADMIN@$HOST" id -un)" = "$ADMIN" || die "New SSH login not verified"
if ((NOPASS)); then ssh "${CHECK[@]}" -p "$OLDPORT" "$ADMIN@$HOST" sudo -n true || die "sudo check failed"
else ssh -tt "${CHECK[@]}" -p "$OLDPORT" "$ADMIN@$HOST" sudo -v || die "sudo check failed"; fi
echo "New SSH key and sudo verified. Applying firewall and SSH hardening..."
ssh -tt "${SSH[@]}" "$TARGET" "$RUN secure '$RDIR/config.env'" || die "Hardening failed; recovery timer may be active"
if ! test "$(ssh "${CHECK[@]}" -p "$NEWPORT" "$ADMIN@$HOST" id -un 2>/dev/null)" = "$ADMIN"; then
 die "New SSH port inaccessible! Keep existing session open; the server will restore SSH automatically after ~10 minutes."
fi
if ((NOPASS)); then ssh "${CHECK[@]}" -p "$NEWPORT" "$ADMIN@$HOST" sudo -n true || die "New-port sudo check failed"
else ssh -tt "${CHECK[@]}" -p "$NEWPORT" "$ADMIN@$HOST" sudo -v || die "New-port sudo check failed"; fi
ssh -tt "${CHECK[@]}" -p "$NEWPORT" "$ADMIN@$HOST" "sudo bash /var/lib/vps-bootstrap/remote.sh confirm /var/lib/vps-bootstrap/config.env" || die "Could not confirm; manual confirmation required"
if [[ -n "$ALIAS" ]]; then
 mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"; touch "$HOME/.ssh/config"; chmod 600 "$HOME/.ssh/config"
 if grep -Eq "^[[:space:]]*Host[[:space:]]+$ALIAS([[:space:]]|$)" "$HOME/.ssh/config"; then
   echo "Existing SSH alias not modified: $ALIAS"
 else
   printf '\nHost %s\n  HostName %s\n  User %s\n  Port %s\n  IdentityFile %s\n  IdentitiesOnly yes\n' "$ALIAS" "$HOST" "$ADMIN" "$NEWPORT" "$PRIV" >> "$HOME/.ssh/config"
 fi
fi
echo "Done: ssh -i $PRIV -p $NEWPORT $ADMIN@$HOST"
