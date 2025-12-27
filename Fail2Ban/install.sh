#!/usr/bin/env bash
# Hardened Fail2Ban installer for Debian (10/11/12/13+)
set -euo pipefail

TS() { date -u +"%Y%m%dT%H%M%SZ"; }
LOG="/var/log/fail2ban-install.log"

# Logging setup
exec > >(tee -a "$LOG") 2>&1

require_root() {
  [ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }
}

install_dependencies() {
  echo "Checking and installing dependencies..."
  apt-get update -qq
  apt-get install -yq fail2ban python3-systemd python3-pyinotify whois || {
    echo "Dependency installation failed"; exit 1; }
  echo "Dependencies verified."
}

ensure_runtime_dirs() {
  echo "Ensuring /run/fail2ban and /var/run consistency..."
  mkdir -p /run/fail2ban
  chmod 0755 /run/fail2ban
  chown root:root /run/fail2ban

  # Ensure /var/run resolves to /run (symlink handling)
  if [ ! -L /var/run ]; then
    [ -d /var/run/fail2ban ] && rm -rf /var/run/fail2ban
    ln -s /run/fail2ban /var/run/fail2ban
  fi

  # Clear any previous fail2ban.sock remnants manually
  [ -e /var/run/fail2ban/fail2ban.sock ] && rm -f /var/run/fail2ban/fail2ban.sock
  echo "Runtime directory cleanup and repair done."

  # Ensure journald-compatible `/var/log/auth.log` placeholder for backward compatibility
  if [ ! -f /var/log/auth.log ]; then
    touch /var/log/auth.log
    chmod 0640 /var/log/auth.log
    chown root:adm /var/log/auth.log || true
    echo "Created placeholder /var/log/auth.log"
  fi
}

write_jail_local() {
  local server_ip ssh_port banaction
  server_ip="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}' | head -n1 || hostname -I | awk '{print $1}')"
  ssh_port=$(awk '/^Port [0-9]+/{print $2}' /etc/ssh/sshd_config 2>/dev/null || echo "ssh")
  banaction=$(command -v nft >/dev/null 2>&1 && systemctl is-active --quiet nftables && echo "nftables-multiport" || echo "iptables-multiport")

  echo "Detected: server_ip=${server_ip}, ssh_port=${ssh_port}, banaction=${banaction}"

  cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 1d
findtime = 10m
maxretry = 5
backend  = systemd
loglevel = INFO
dbfile   = /var/lib/fail2ban/fail2ban.sqlite3
ignoreip = 127.0.0.1/8 ::1 ${server_ip}
banaction= ${banaction}

[sshd]
enabled = true
port    = ${ssh_port}
journalmatch = _SYSTEMD_UNIT=sshd.service + _COMM=sshd
EOF
  echo "Wrote jail.local configuration in /etc/fail2ban/jail.local"
}

validate_config() {
  if ! fail2ban-server -t >/dev/null 2>&1; then
    echo "Validation failed for jail.local. Check the Fail2Ban runtime environment."
    exit 1
  else
    echo "Jail configuration validation complete."
  fi
}

cleanup_systemd_override() {
  local override_file=/etc/systemd/system/fail2ban.service.d/override.conf
  if [ -f "$override_file" ]; then
    mv "$override_file" "${override_file}.bak.$(TS)" || true
    echo "Removed or backed-up the old override.conf file."
  fi
}

restart_fail2ban() {
  echo "Reloading Fail2Ban services and capturing diagnostics..."
  systemctl daemon-reload
  systemctl enable --now fail2ban || true

  for _ in {1..20}; do
    if fail2ban-client ping &>/dev/null; then
      echo "Fail2Ban successfully restarted and running correctly."
      return
    fi
    sleep 2
  done

  echo "Service failed; attempting fallback strategies below."
}

manual_debug_fallbacks() {
  echo "==== Diagnostics: Tail recent logs ===="
  journalctl -u fail2ban | tail -n 25 || true

  echo "Attempting direct fail2ban-server debug:"
  timeout 8s fail2ban-server -xf start || true
}

main() {
  require_root
  echo "Fail2Ban installer started at: $(TS)"
  install_dependencies
  ensure_runtime_dirs
  write_jail_local
  validate_config
  cleanup_systemd_override
  restart_fail2ban || manual_debug_fallbacks
  echo "Install runtime persisted -> $LOG"
}

main "$@"