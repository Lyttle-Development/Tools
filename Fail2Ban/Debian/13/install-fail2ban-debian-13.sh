#!/usr/bin/env bash
# install-fail2ban-debian-13.sh
# Idempotent installer and configurator for fail2ban on Debian 13 (trixie).
#
# Fixes for minimal/journald-only VPS images:
# - installs fail2ban WITH recommended dependencies (python3-systemd / pyinotify) so journald backend works reliably
# - ensures /var/log/auth.log exists (placeholder) for configs that expect it
# - prefers journalmode + journalmatch for sshd when auth.log isn't present
# - ensures runtime and DB directories exist
# - validates configuration and captures diagnostics on failure
# - starts fail2ban in daemon mode (not foreground -xf) to avoid systemd Type=simple exit-255 race
#
# Run as root or via sudo. 
set -euo pipefail

timestamp() { date -u +"%Y%m%dT%H%M%SZ"; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root.   Use sudo." >&2
    exit 1
  fi
}

detect_debian_13() {
  if [ -r /etc/os-release ]; then
    .  /etc/os-release
    if [ "${ID:-}" != "debian" ]; then
      echo "Warning:  This script is targeted for Debian 13. Detected:  ${PRETTY_NAME:-$ID $VERSION_ID}" >&2
    fi
    if [ -n "${VERSION_ID:-}" ] && [ "${VERSION_ID:-}" != "13" ]; then
      echo "Warning: This script is targeted for Debian 13. Detected version: ${VERSION_ID}" >&2
    fi
  fi
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -yq fail2ban python3-systemd python3-pyinotify whois || {
    echo "apt-get install failed" >&2
    exit 1
  }
}

detect_primary_ipv4() {
  local ip
  ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}' | head -n1 || true)
  if [ -z "$ip" ]; then
    ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  fi
  echo "${ip:-}"
}

detect_ssh_port() {
  local port
  port=$(awk '/^Port[[:space:]]+[0-9]+/ {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || true)
  if [ -z "$port" ]; then
    echo "ssh"
  else
    echo "$port"
  fi
}

detect_banaction() {
  # Prefer nftables on Debian 13, then ufw, else iptables-multiport
  if command -v nft >/dev/null 2>&1 && systemctl is-active --quiet nftables 2>/dev/null; then
    echo "nftables-multiport"
    return
  fi
  if command -v ufw >/dev/null 2>&1 && systemctl is-active --quiet ufw 2>/dev/null; then
    echo "ufw"
    return
  fi
  echo "iptables-multiport"
}

backup_existing() {
  local file=$1
  if [ -f "$file" ]; then
    local b="/etc/fail2ban/$(basename "$file").backup.$(timestamp)"
    cp -a "$file" "$b"
    echo "Backed up existing $file -> $b"
  fi
}

ensure_runtime_dir() {
  local dir=/run/fail2ban
  if [ !  -d "$dir" ]; then
    mkdir -p "$dir"
    chmod 0755 "$dir"
    chown root: root "$dir" 2>/dev/null || true
    echo "Created $dir"
  fi
}

ensure_auth_log() {
  local f=/var/log/auth.log
  if [ ! -e "$f" ]; then
    touch "$f"
    if getent group adm >/dev/null 2>&1; then
      chown root:adm "$f" 2>/dev/null || true
      chmod 0640 "$f" 2>/dev/null || true
    else
      chown root:root "$f" 2>/dev/null || true
      chmod 0600 "$f" 2>/dev/null || true
    fi
    echo "Created placeholder $f"
  fi
}

ensure_db_dir() {
  local dir=/var/lib/fail2ban
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir"
    chown root:root "$dir" 2>/dev/null || true
    chmod 0755 "$dir" 2>/dev/null || true
    echo "Created $dir"
  fi
}

write_jail_local() {
  local jail_local=/etc/fail2ban/jail.local
  local server_ip="$1"
  local ssh_port="$2"
  local banaction="$3"

  backup_existing "$jail_local"

  local use_auth_log=0
  if [ -r /var/log/auth. log ] && [ -s /var/log/auth.log ]; then
    use_auth_log=1
  fi

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
    cat >> "$jail_local" <<'EOF'
logpath = /var/log/auth.log
EOF
  else
    cat >> "$jail_local" <<'EOF'
journalmatch = _SYSTEMD_UNIT=sshd.service + _COMM=sshd
EOF
  fi

  chmod 644 "$jail_local"
  echo "Wrote $jail_local (sshd using $( [ "$use_auth_log" -eq 1 ] && echo auth.log || echo systemd journal ))"
}

validate_config() {
  echo "Validating fail2ban configuration..."
  if ! fail2ban-server -t 2>&1 | tee /tmp/fail2ban-config-test.log; then
    echo "fail2ban configuration test failed. See /tmp/fail2ban-config-test.log" >&2
    cat /tmp/fail2ban-config-test.log >&2
    exit 1
  fi
}

# Override systemd unit to use daemon mode (background) instead of foreground
fix_systemd_unit() {
  local override_dir=/etc/systemd/system/fail2ban.service.d
  local override_file="$override_dir/override.conf"
  
  mkdir -p "$override_dir"
  
  cat > "$override_file" <<'EOF'
[Service]
# Override ExecStart to use daemon mode (background) instead of foreground -xf
# This prevents the exit-255 race condition with systemd Type=simple
ExecStart=
ExecStart=/usr/bin/fail2ban-server -s /run/fail2ban/fail2ban.sock -p /run/fail2ban/fail2ban.pid start
EOF
  
  echo "Created systemd override at $override_file"
}

service_start_and_check() {
  local install_log=/var/log/fail2ban-install. log
  : > "$install_log"

  systemctl daemon-reload

  systemctl enable fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban >/dev/null 2>&1 || true

  local tries=0
  local max_tries=25
  while [ $tries -lt $max_tries ]; do
    if fail2ban-client ping >/dev/null 2>&1; then
      echo "fail2ban running"
      return 0
    fi
    tries=$((tries + 1))
    sleep 1
  done

  echo "fail2ban service did not start within ${max_tries}s — collecting diagnostics..." | tee -a "$install_log"
  echo "---- systemctl status fail2ban ----" | tee -a "$install_log"
  systemctl status fail2ban -l --no-pager 2>&1 | tee -a "$install_log"
  echo "---- journalctl -u fail2ban (last 600 lines) ----" | tee -a "$install_log"
  journalctl -u fail2ban -b --no-pager -n 600 2>&1 | tee -a "$install_log"

  echo "---- /etc/fail2ban/jail.local ----" | tee -a "$install_log"
  sed -n '1,200p' /etc/fail2ban/jail.local 2>&1 | tee -a "$install_log"

  echo "Diagnostics saved to $install_log" >&2
  echo "---- tail of $install_log ----"
  tail -n 160 "$install_log" || true

  return 2
}

post_install_checks() {
  echo
  echo "fail2ban status:"
  fail2ban-client status || true
  echo
  echo "sshd jail status:"
  fail2ban-client status sshd || true
  echo
  echo "To follow fail2ban logs:  sudo journalctl -u fail2ban -f"
}

main() {
  require_root
  detect_debian_13

  echo "Installing fail2ban..."
  apt_install

  local server_ip
  server_ip=$(detect_primary_ipv4)
  if [ -z "$server_ip" ]; then
    echo "Could not detect a primary IPv4 address automatically; no server IP will be added to ignoreip." >&2
  fi

  local ssh_port
  ssh_port=$(detect_ssh_port)

  local banaction
  banaction=$(detect_banaction)

  echo "Detected values: server_ip=${server_ip:-<none>}, ssh_port=${ssh_port}, banaction=${banaction}"

  ensure_runtime_dir
  ensure_auth_log
  ensure_db_dir

  write_jail_local "${server_ip:-}" "${ssh_port}" "$banaction"
  validate_config

  fix_systemd_unit

  if !  service_start_and_check; then
    echo "Failed to start fail2ban. Check /var/log/fail2ban-install.log for details." >&2
    exit 1
  fi

  post_install_checks

  echo
  echo "Done. Edit /etc/fail2ban/jail.local to adjust ignoreip or fine-tune bantime/findtime/maxretry."
}

main "$@"