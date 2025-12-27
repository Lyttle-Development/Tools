#!/usr/bin/env bash
# install-fail2ban-debian.sh
# Universal Debian setup: Catch-all fixes for runtime/socket issues.

set -euo pipefail

timestamp() { date -u +"%Y%m%dT%H%M%SZ"; }
require_root() { [ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }; }

detect_debian() {
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    if [ "${ID:-}" != "debian" ]; then
      echo "Warning: ${PRETTY_NAME:-$ID $VERSION_ID} detected (not Debian). Continuing anyway."; fi
    echo "Detected: ${PRETTY_NAME:-Debian $VERSION_ID}"
  fi
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -yq fail2ban python3-systemd python3-pyinotify whois || {
    echo "apt-get install failed" >&2; exit 1; }
}

detect_primary_ipv4() {
  ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}' | head -n1 || true)
  [ -z "$ip" ] && { ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true); }
  echo "${ip:-127.0.0.1}"
}

detect_ssh_port() {
  port=$(awk '/^Port[[:space:]]+[0-9]+/ {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || true)
  echo "${port:-ssh}"
}

detect_banaction() {
  if command -v nft >/dev/null 2>&1 && systemctl is-active --quiet nftables 2>/dev/null; then
    echo "nftables-multiport"; return; fi
  if command -v ufw >/dev/null 2>&1 && systemctl is-active --quiet ufw 2>/dev/null; then
    echo "ufw"; return; fi
  echo "iptables-multiport"
}

ensure_dirs_and_permissions() {
  mkdir -p /run/fail2ban /var/lib/fail2ban
  chmod 0755 /run/fail2ban /var/lib/fail2ban
  chown root:root /run/fail2ban /var/lib/fail2ban
  # Placeholder for auth.log in journald-only systems
  [ ! -f /var/log/auth.log ] && { touch /var/log/auth.log; chmod 0640 /var/log/auth.log; chown root:adm /var/log/auth.log; }
}

write_jail_local() {
  local jail_local=/etc/fail2ban/jail.local
  backup_existing "$jail_local"

  local server_ip="$1"; local ssh_port="$2"; local banaction="$3"
  cat > "$jail_local" <<EOF
[DEFAULT]
bantime = 1d
findtime = 10m
maxretry = 5
backend = systemd
dbfile = /var/lib/fail2ban/fail2ban.sqlite3
ignoreip = 127.0.0.1/8 ::1 $server_ip
banaction = $banaction
loglevel = INFO

[sshd]
enabled = true
port = $ssh_port
journalmatch = _SYSTEMD_UNIT=sshd.service + _COMM=sshd
EOF
  chmod 0644 "$jail_local"
}

backup_existing() {
  local file=$1
  [ -f "$file" ] && cp -a "$file" "${file}.backup.$(timestamp)" && echo "Backed up $file -> ${file}.backup.$(timestamp)"
}

fix_systemd_override() {
  local override_dir=/etc/systemd/system/fail2ban.service.d
  mkdir -p "$override_dir"
  local override_file="$override_dir/override.conf"
  cat > "$override_file" <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/fail2ban-server -s /run/fail2ban/fail2ban.sock -p /run/fail2ban/fail2ban.pid start
EOF
  echo "Created systemd override at $override_file"
}

validate_config() {
  fail2ban-server -t &>/tmp/fail2ban-config-test.log || {
    cat /tmp/fail2ban-config-test.log; exit 1; }
}

service_start_and_wait() {
  systemctl daemon-reload
  systemctl enable fail2ban
  systemctl start fail2ban

  local timeout=20
  local i=0
  while ((i < timeout)); do
    if fail2ban-client ping &>/dev/null; then
      echo "fail2ban successfully started."; return 0
    fi
    sleep 1; ((i++))
  done

  echo "Fail2Ban failed to start within $timeout seconds. Collecting diagnostics..."; collect_diagnostics
}

collect_diagnostics() {
  {
    echo "---- SYSTEMCTL STATUS ----"
    systemctl status fail2ban
    echo "---- JOURNALCTL LOG ----"
    journalctl -u fail2ban -n 100
  } >/tmp/fail2ban-diagnostics.log 2>&1
  echo "Diagnostics written to /tmp/fail2ban-diagnostics.log";
  cat /tmp/fail2ban-diagnostics.log
  exit 1
}

main() {
  require_root
  detect_debian

  echo "Installing fail2ban and dependencies..."
  apt_install

  echo "Ensuring directories and permissions..."
  ensure_dirs_and_permissions

  local server_ip; local ssh_port; local banaction
  server_ip=$(detect_primary_ipv4)
  ssh_port=$(detect_ssh_port)
  banaction=$(detect_banaction)

  echo "Detected: server_ip=$server_ip, ssh_port=$ssh_port, banaction=$banaction"

  echo "Writing jail.local configuration..."
  write_jail_local "$server_ip" "$ssh_port" "$banaction"

  echo "Fixing systemd override..."
  fix_systemd_override

  echo "Validating configuration..."
  validate_config

  echo "Starting Fail2Ban service..."
  service_start_and_wait

  echo "Installation completed successfully. Check status with: sudo systemctl status fail2ban"
}

main "$@"