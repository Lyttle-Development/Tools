#!/usr/bin/env bash
# install-fail2ban-debian.sh
# Universal: Debian 10/11/12/13+

set -euo pipefail

timestamp() { date -u +"%Y%m%dT%H%M%SZ"; }
require_root() { [ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }; }

detect_debian() {
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    if [ "${ID:-}" != "debian" ]; then
      echo "Warning: Detected ${PRETTY_NAME:-$ID $VERSION_ID} (not Debian)"; fi
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
  [ -z "$ip" ] && ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  echo "${ip:-}"
}

detect_ssh_port() {
  port=$(awk '/^Port[[:space:]]+[0-9]+/ {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || true)
  [ -z "$port" ] && echo "ssh" || echo "$port"
}

detect_banaction() {
  if command -v nft >/dev/null 2>&1 && systemctl is-active --quiet nftables 2>/dev/null; then
    echo "nftables-multiport"; return; fi
  if command -v ufw >/dev/null 2>&1 && systemctl is-active --quiet ufw 2>/dev/null; then
    echo "ufw"; return; fi
  echo "iptables-multiport"
}

backup_existing() {
  local file=$1
  [ -f "$file" ] && cp -a "$file" "/etc/fail2ban/$(basename "$file").backup.$(timestamp)" && echo "Backed up existing $file"
}

ensure_runtime_dir() { mkdir -p /run/fail2ban && chmod 0755 /run/fail2ban && chown root:root /run/fail2ban 2>/dev/null || true; }
ensure_auth_log() {
  f=/var/log/auth.log
  [ ! -e "$f" ] && touch "$f"
  if getent group adm >/dev/null 2>&1; then chown root:adm "$f"; chmod 0640 "$f"; else chown root:root "$f"; chmod 0600 "$f"; fi
}
ensure_db_dir() { mkdir -p /var/lib/fail2ban && chown root:root /var/lib/fail2ban && chmod 0755 /var/lib/fail2ban; }

write_jail_local() {
  local jail_local=/etc/fail2ban/jail.local; local server_ip="$1"; local ssh_port="$2"; local banaction="$3"
  backup_existing "$jail_local"
  local use_auth_log=0; [ -r /var/log/auth.log ] && [ -s /var/log/auth.log ] && use_auth_log=1
  cat > "$jail_local" <<EOF
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
maxretry = 5
EOF
  if [ "$use_auth_log" -eq 1 ]; then
    echo "logpath = /var/log/auth.log" >> "$jail_local"
  else
    echo "journalmatch = _SYSTEMD_UNIT=sshd.service + _COMM=sshd" >> "$jail_local"
  fi
  chmod 644 "$jail_local"
  echo "Wrote $jail_local (sshd using $( [ "$use_auth_log" -eq 1 ] && echo auth.log || echo systemd journal ))"
}

validate_config() {
  echo "Validating fail2ban configuration..."
  fail2ban-server -t 2>&1 | tee /tmp/fail2ban-config-test.log || {
    cat /tmp/fail2ban-config-test.log >&2; exit 1; }
}

fix_systemd_unit() {
  local override_dir=/etc/systemd/system/fail2ban.service.d
  local override_file="$override_dir/override.conf"
  mkdir -p "$override_dir"
  cat > "$override_file" <<'EOF'
[Service]
# Fix: always use daemon mode and correct socket path
ExecStart=
ExecStart=/usr/bin/fail2ban-server -s /run/fail2ban/fail2ban.sock -p /run/fail2ban/fail2ban.pid start
EOF
  echo "Created systemd override at $override_file"
}

service_start_and_check() {
  install_log=/var/log/fail2ban-install.log; : > "$install_log"
  systemctl daemon-reload; systemctl enable fail2ban; systemctl restart fail2ban
  n=0; while [ $n -lt 25 ]; do
    fail2ban-client ping >/dev/null 2>&1 && { echo "fail2ban running"; return 0; }
    n=$((n+1)); sleep 1; done
  echo "fail2ban did not start in time, running diagnostics..." | tee -a "$install_log"
  systemctl status fail2ban -l --no-pager | tee -a "$install_log"
  journalctl -u fail2ban -b --no-pager -n 600 | tee -a "$install_log"
  tail -n 160 "$install_log" || true; return 2
}

post_install_checks() {
  echo; echo "fail2ban status:"; fail2ban-client status || true
  echo; echo "sshd jail status:"; fail2ban-client status sshd || true
  echo; echo "To follow fail2ban logs:  sudo journalctl -u fail2ban -f"
}

main() {
  require_root; detect_debian; echo "Installing fail2ban..."; apt_install
  local server_ip ssh_port banaction
  server_ip=$(detect_primary_ipv4); ssh_port=$(detect_ssh_port); banaction=$(detect_banaction)
  echo "Detected values: server_ip=${server_ip:-<none>}, ssh_port=${ssh_port}, banaction=${banaction}"
  ensure_runtime_dir; ensure_auth_log; ensure_db_dir
  write_jail_local "${server_ip:-}" "${ssh_port}" "$banaction"; validate_config; fix_systemd_unit
  if ! service_start_and_check; then echo "Failed to start fail2ban. See /var/log/fail2ban-install.log." >&2; exit 1; fi
  post_install_checks
  echo; echo "Done. Edit /etc/fail2ban/jail.local to adjust ignoreip or fine-tune bantime/findtime/maxretry."
}
main "$@"