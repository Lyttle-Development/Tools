#!/usr/bin/env bash
# install-fail2ban-debian.sh
# Universal installer for Debian. Detects and repairs all /run and /var/run/fail2ban circular symlinks.

set -euo pipefail

TS() { date -u +"%Y%m%dT%H%M%SZ"; }
LOG="/var/log/fail2ban-install.log"
exec > >(tee -a "$LOG") 2>&1

require_root() { [ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }; }

repair_run_dirs() {
  echo "Checking /run and /var/run..."
  # Remove bad dirs/symlinks for /var/run/fail2ban and /run/fail2ban
  for DIR in /run/fail2ban /var/run/fail2ban; do
    if [ -L "$DIR" ]; then
      echo "$DIR is a symlink, removing"
      rm -f "$DIR"
    elif [ -e "$DIR" ] && [ ! -d "$DIR" ]; then
      echo "$DIR exists and is not a directory, removing"
      rm -rf "$DIR"
    fi
  done

  # Ensure /run/fail2ban is a directory, never a symlink
  if [ ! -d /run/fail2ban ]; then
    mkdir -m 0755 /run/fail2ban
    chown root:root /run/fail2ban
    echo "/run/fail2ban created as directory"
  fi

  # /var/run is a symlink to /run on Debian, so /var/run/fail2ban just becomes /run/fail2ban
  # Ensure there is NO /var/run/fail2ban symlink, log if /var/run is not a symlink (unusual)
  if [ ! -L /var/run ] && [ ! -e /var/run/fail2ban ]; then
    ln -s /run/fail2ban /var/run/fail2ban
    echo "/var/run is not a symlink, created link /var/run/fail2ban -> /run/fail2ban"
  fi

  # Log the status
  echo "Directory status after repair:"
  ls -lad /run /var/run /run/fail2ban /var/run/fail2ban || true
}

install_deps() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -yq fail2ban python3-systemd python3-pyinotify whois
}

detect_primary_ipv4() {
  ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}' | head -n1 || true)
  [ -z "$ip" ] && ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  echo "${ip:-127.0.0.1}"
}

detect_ssh_port() {
  awk '/^Port[[:space:]]*[0-9]+/ {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || echo "ssh"
}

detect_banaction() {
  if command -v nft >/dev/null 2>&1 && systemctl is-active --quiet nftables 2>/dev/null; then echo "nftables-multiport"; return; fi
  if command -v ufw >/dev/null 2>&1 && systemctl is-active --quiet ufw 2>/dev/null; then echo "ufw"; return; fi
  echo "iptables-multiport"
}

write_jail_local() {
  server_ip="$1"; ssh_port="$2"; banaction="$3"
  jail=/etc/fail2ban/jail.local
  [ -f "$jail" ] && cp -a "$jail" "${jail}.backup.$(TS)"
  cat > "$jail" <<EOF
[DEFAULT]
bantime = 1d
findtime = 10m
maxretry = 5
backend = systemd
dbfile = /var/lib/fail2ban/fail2ban.sqlite3
ignoreip = 127.0.0.1/8 ::1 ${server_ip}
banaction = ${banaction}
loglevel = INFO

[sshd]
enabled = true
port = ${ssh_port}
journalmatch = _SYSTEMD_UNIT=sshd.service + _COMM=sshd
maxretry = 5
EOF
  chmod 0644 "$jail"
  echo "Wrote $jail"
}

ensure_other_files() {
  mkdir -p /var/lib/fail2ban
  chown root:root /var/lib/fail2ban
  chmod 0755 /var/lib/fail2ban
  # Journald compatibility
  [ ! -e /var/log/auth.log ] && { touch /var/log/auth.log; chmod 0640 /var/log/auth.log; chown root:adm /var/log/auth.log || true; }
}

cleanup_bad_override() {
  local override_file=/etc/systemd/system/fail2ban.service.d/override.conf
  if [ -f "$override_file" ]; then
    mv "$override_file" "${override_file}.bak.$(TS)" || true
    echo "Removed/Backed-up old override.conf"
  fi
}

validate_config() {
  if ! fail2ban-server -t >/tmp/fail2ban-config-test.log 2>&1; then
    echo "Config test failed:"; sed -n '1,240p' /tmp/fail2ban-config-test.log; exit 1
  fi
}

start_and_check() {
  systemctl daemon-reload
  systemctl enable --now fail2ban
  for t in {1..20}; do
    if fail2ban-client ping >/dev/null 2>&1; then
      echo "Fail2Ban running and socket is up. Success!"
      return 0
    fi
    sleep 1
  done
  echo "Fail2Ban did not start or socket not accessible after repair/restart."
  systemctl status fail2ban || true
  journalctl -u fail2ban --no-pager | tail -n 50 || true
  exit 1
}

main() {
  require_root
  echo "Install started at $(TS)"
  install_deps
  repair_run_dirs
  ensure_other_files

  server_ip=$(detect_primary_ipv4)
  ssh_port=$(detect_ssh_port)
  banaction=$(detect_banaction)
  echo "Detected: server_ip=$server_ip, ssh_port=$ssh_port, banaction=$banaction"

  write_jail_local "$server_ip" "$ssh_port" "$banaction"
  cleanup_bad_override
  validate_config

  start_and_check
}

main "$@"