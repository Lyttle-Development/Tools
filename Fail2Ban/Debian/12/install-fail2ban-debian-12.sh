#!/usr/bin/env bash
# install-fail2ban-debian12.sh
# Idempotent installer and configurator for fail2ban on Debian 12 (bookworm).
# Enhancements:
# - validates fail2ban configuration before starting
# - creates runtime directory if missing
# - retries service start and checks fail2ban socket
# - captures diagnostics/logs on failure to /var/log/fail2ban-install.log
# - retains previous behavior: detects firewall backend, primary IP, ssh port, writes /etc/fail2ban/jail.local
set -euo pipefail

timestamp() { date -u +"%Y%m%dT%H%M%SZ"; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Use sudo." >&2
    exit 1
  fi
}

detect_debian_12() {
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    if [ "${ID:-}" != "debian" ] || [ "${VERSION_ID:-}" != "12" ]; then
      echo "Warning: targeted for Debian 12. Detected: ${PRETTY_NAME:-$ID $VERSION_ID}" >&2
      # continue anyway
    fi
  fi
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -yq --no-install-recommends fail2ban || {
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
  if command -v nft >/dev/null 2>&1 && systemctl is-active --quiet nftables; then
    echo "nftables-multiport"
    return
  fi
  if command -v ufw >/dev/null 2>&1 && systemctl is-active --quiet ufw; then
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

write_jail_local() {
  local jail_local=/etc/fail2ban/jail.local
  local server_ip="$1"
  local ssh_port="$2"
  local banaction="$3"

  backup_existing "$jail_local"

  cat > "$jail_local" <<EOF
[DEFAULT]
# Ban settings
bantime = 1d
findtime = 10m
maxretry = 5

# Use systemd journal on Debian 12 for robust log reading
backend = systemd

# Whitelist trusted IPs - script auto-added server's primary IP below.
# Edit this file to add your static office/home IPs (separate by space).
ignoreip = 127.0.0.1/8 ::1 ${server_ip}

# Choose firewall action (detected by installer):
banaction = ${banaction}

# Recommended: use a logging level suitable for debugging during setup, then set to INFO in production
loglevel = INFO

[sshd]
enabled = true
port = ${ssh_port}
logpath = %(sshd_log)s
maxretry = 5
EOF

  chmod 644 "$jail_local"
  echo "Wrote $jail_local"
}

ensure_runtime_dir() {
  # Ensure /run/fail2ban exists and has safe perms
  local dir=/run/fail2ban
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir"
    chmod 0755 "$dir"
    chown root:root "$dir" || true
    echo "Created $dir"
  fi
}

service_start_and_check() {
  local install_log=/var/log/fail2ban-install.log
  : > "$install_log"
  systemctl daemon-reload || true
  systemctl enable --now fail2ban || true

  # Retry loop: wait for fail2ban-server to respond via fail2ban-client ping
  local tries=0
  local max_tries=10
  local sleep_sec=1
  while [ $tries -lt $max_tries ]; do
    if fail2ban-client ping >/dev/null 2>&1; then
      echo "fail2ban running"
      return 0
    fi
    tries=$((tries + 1))
    sleep $sleep_sec
  done

  # If we reached here, service didn't start properly. Gather diagnostics.
  echo "fail2ban service did not start within ${max_tries}s — collecting diagnostics..." | tee -a "$install_log"
  echo "---- systemctl status fail2ban ----" | tee -a "$install_log"
  systemctl status fail2ban -l --no-pager 2>&1 | tee -a "$install_log"
  echo "---- journalctl -u fail2ban (last 200 lines) ----" | tee -a "$install_log"
  journalctl -u fail2ban -b --no-pager -n 200 2>&1 | tee -a "$install_log"

  # Try to run server in foreground to capture errors (non-blocking background redirect)
  echo "Attempting foreground run to capture errors to $install_log" | tee -a "$install_log"
  # Start foreground server for a short period to capture startup errors, kill after 6s if still running.
  # Using nohup so it doesn't die with the script; run with -xf (foreground & debug)
  if command -v fail2ban-server >/dev/null 2>&1; then
    nohup bash -c 'fail2ban-server -xf start' >>"$install_log" 2>&1 &
    sleep 6
    # if still running, kill it (we only wanted startup output)
    pkill -f "fail2ban-server -xf start" || true
  fi

  echo "Diagnostics saved to $install_log" >&2
  return 2
}

post_install_checks() {
  echo
  echo "fail2ban status:"
  fail2ban-client status || true
  echo
  echo "sshd jail status (if present):"
  fail2ban-client status sshd || true
  echo
  echo "To follow fail2ban logs: sudo journalctl -u fail2ban -f"
}

main() {
  require_root
  detect_debian_12

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

  write_jail_local "${server_ip:-}" "${ssh_port}" "$banaction"

  # Validate fail2ban config before starting
  echo "Validating fail2ban configuration..."
  if ! fail2ban-server -t 2>&1 | tee /tmp/fail2ban-config-test.log; then
    echo "fail2ban configuration test failed. See /tmp/fail2ban-config-test.log" >&2
    cat /tmp/fail2ban-config-test.log >&2
    exit 1
  fi

  ensure_runtime_dir

  # Start and verify
  if ! service_start_and_check; then
    echo "Failed to start fail2ban. Check /var/log/fail2ban-install.log for details." >&2
    exit 1
  fi

  post_install_checks

  echo
  echo "Done. Edit /etc/fail2ban/jail.local to adjust ignoreip or fine-tune bantime/findtime/maxretry."
}

main "$@"