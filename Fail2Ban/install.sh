#!/usr/bin/env bash
# install-fail2ban-debian.sh
# Single-shot installer for Debian (10/11/12/13+) with robust socket/startup recovery.
# - installs recommended packages
# - writes safe /etc/fail2ban/jail.local using journalmatch when auth.log not present
# - ensures /run and /var/run fail2ban directories exist with correct perms
# - validates configuration
# - attempts service start, retries, collects diagnostics, and falls back to daemon/manual start for recovery
#
# Run as root (sudo).

set -euo pipefail

TS() { date -u +"%Y%m%dT%H%M%SZ"; }
LOG="/tmp/fail2ban-install-${TS()}.log"
exec > >(tee -a "$LOG") 2>&1

require_root() {
  [ "$(id -u)" -eq 0 ] || { echo "Must run as root"; exit 1; }
}

install_pkgs() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -yq fail2ban python3-systemd python3-pyinotify whois
}

detect_primary_ipv4() {
  ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}' | head -n1 || true)
  [ -z "$ip" ] && ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  echo "${ip:-}"
}

detect_ssh_port() {
  awk '/^Port[[:space:]]+[0-9]+/ {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || echo "ssh"
}

detect_banaction() {
  if command -v nft >/dev/null 2>&1 && systemctl is-active --quiet nftables 2>/dev/null; then
    echo "nftables-multiport"; return
  fi
  if command -v ufw >/dev/null 2>&1 && systemctl is-active --quiet ufw 2>/dev/null; then
    echo "ufw"; return
  fi
  echo "iptables-multiport"
}

ensure_dirs() {
  mkdir -p /run/fail2ban /var/run/fail2ban /var/lib/fail2ban
  chmod 0755 /run/fail2ban /var/lib/fail2ban
  chown root:root /run/fail2ban /var/lib/fail2ban || true

  # ensure auth.log placeholder (safe perms) to avoid logpath resolution failures on journald-only systems
  if [ ! -e /var/log/auth.log ]; then
    touch /var/log/auth.log
    if getent group adm >/dev/null 2>&1; then
      chown root:adm /var/log/auth.log || true
      chmod 0640 /var/log/auth.log || true
    else
      chown root:root /var/log/auth.log || true
      chmod 0600 /var/log/auth.log || true
    fi
  fi
}

backup_if_exists() {
  f="$1"
  [ -f "$f" ] && cp -a "$f" "${f}.backup.$(TS)" && echo "Backed up $f"
}

write_jail_local() {
  local server_ip="$1" ssh_port="$2" banaction="$3"
  local jail=/etc/fail2ban/jail.local
  backup_if_exists "$jail"

  # prefer journalmatch to avoid "Have not found any log file" on journald-only systems
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

validate_config() {
  if ! fail2ban-server -t; then
    echo "fail2ban configuration test failed. See $LOG"; return 1
  fi
  echo "Configuration OK"
}

systemd_reload_and_restart() {
  systemctl daemon-reload || true
  systemctl enable --now fail2ban || true
}

wait_for_ping() {
  local timeout=${1:-25}
  local i=0
  while [ $i -lt "$timeout" ]; do
    if fail2ban-client ping >/dev/null 2>&1; then
      echo "fail2ban-client ping OK"
      return 0
    fi
    sleep 1
    i=$((i+1))
  done
  return 1
}

collect_diagnostics() {
  echo "==== systemctl status fail2ban ===="
  systemctl status fail2ban --no-pager || true
  echo "==== journalctl -u fail2ban (last 200 lines) ===="
  journalctl -u fail2ban -b --no-pager -n 200 || true
  echo "==== /run and /var/run listing ===="
  ls -la /run/fail2ban /var/run/fail2ban || true
  echo "==== /etc/fail2ban/jail.local ===="
  sed -n '1,240p' /etc/fail2ban/jail.local || true
}

attempt_daemon_start() {
  echo "Attempting direct daemon start: fail2ban-server start"
  # Try packaged daemon start (background)
  if fail2ban-server start >/tmp/fail2ban-direct.start 2>&1; then
    sleep 1
    if fail2ban-client ping >/dev/null 2>&1; then
      echo "Started via fail2ban-server start"
      return 0
    fi
  fi
  echo "Direct daemon start failed, log:"
  tail -n 200 /tmp/fail2ban-direct.start || true
  return 1
}

attempt_foreground_debug() {
  echo "Running foreground debug for 8s to capture errors (output -> /tmp/fail2ban-debug.log)"
  timeout 8s fail2ban-server -xf start &>/tmp/fail2ban-debug.log || true
  echo "---- tail /tmp/fail2ban-debug.log ----"
  tail -n 200 /tmp/fail2ban-debug.log || true
}

main() {
  require_root
  echo "Start: $(TS)"
  install_pkgs
  server_ip=$(detect_primary_ipv4)
  ssh_port=$(detect_ssh_port)
  banaction=$(detect_banaction)
  echo "Detected: server_ip=${server_ip}, ssh_port=${ssh_port}, banaction=${banaction}"

  ensure_dirs
  write_jail_local "$server_ip" "$ssh_port" "$banaction"

  if ! validate_config; then
    echo "Validation failed; aborting"; exit 1
  fi

  # ensure any old bad override removed (cleanup)
  if [ -f /etc/systemd/system/fail2ban.service.d/override.conf ]; then
    mv /etc/systemd/system/fail2ban.service.d/override.conf "/etc/systemd/system/fail2ban.service.d/override.conf.bak.$(TS)" || true
    echo "Backed up existing systemd override"
  fi

  systemd_reload_and_restart

  if wait_for_ping 20; then
    echo "Fail2Ban running via systemd"
    exit 0
  fi

  echo "systemd start failed; gathering diagnostics"
  collect_diagnostics

  # try direct daemon start (packaged start)
  if attempt_daemon_start; then
    echo "Fail2Ban running after direct daemon start"
    exit 0
  fi

  # fallback: run foreground debug to capture exact error
  attempt_foreground_debug

  echo "Failed to start Fail2Ban. Full diagnostics logged above and in $LOG"
  exit 1
}

main "$@"