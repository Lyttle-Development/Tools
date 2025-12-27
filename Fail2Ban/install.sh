#!/usr/bin/env bash
# install-fail2ban-debian.sh
# Single-command installer + robust diagnostics and recovery for Fail2Ban on Debian (10/11/12/13+).
# Writes persistent installer log to /var/log/fail2ban-install.log for post-run inspection.
#
# Run as root (sudo).
set -euo pipefail

TS() { date -u +"%Y%m%dT%H%M%SZ"; }
PERSIST_LOG="/var/log/fail2ban-install.log"
TMP_LOG="/tmp/fail2ban-install-$(TS).log"

# Backup existing persistent log
if [ -f "$PERSIST_LOG" ]; then
  cp -a "$PERSIST_LOG" "${PERSIST_LOG}.bak.$(TS)" || true
fi
# Open logging: append to persistent log and to a per-run tmp file simultaneously
exec > >(tee -a "$PERSIST_LOG" "$TMP_LOG") 2>&1

require_root() { [ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }; }

install_deps() {
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
  if command -v nft >/dev/null 2>&1 && systemctl is-active --quiet nftables 2>/dev/null; then echo "nftables-multiport"; return; fi
  if command -v ufw >/dev/null 2>&1 && systemctl is-active --quiet ufw 2>/dev/null; then echo "ufw"; return; fi
  echo "iptables-multiport"
}

ensure_run_dirs() {
  mkdir -p /run/fail2ban /var/lib/fail2ban
  chmod 0755 /run/fail2ban /var/lib/fail2ban || true
  chown root:root /run/fail2ban /var/lib/fail2ban || true

  # ensure /var/run/fail2ban points to /run/fail2ban to avoid path mismatches
  if [ -e /var/run ] && [ ! -L /var/run/fail2ban ]; then
    rm -rf /var/run/fail2ban 2>/dev/null || true
    ln -sfn /run/fail2ban /var/run/fail2ban
  fi

  # ensure auth.log placeholder for journald-only images
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

  # ensure persistent installer log exists and is writable
  touch "$PERSIST_LOG" || true
  chmod 0644 "$PERSIST_LOG" || true
  chown root:root "$PERSIST_LOG" || true

  echo "Ensured runtime dirs, auth.log placeholder and installer log at $PERSIST_LOG"
}

backup_if_exists() {
  f="$1"
  [ -f "$f" ] && cp -a "$f" "${f}.backup.$(TS)" && echo "Backed up $f -> ${f}.backup.$(TS)"
}

write_jail_local() {
  server_ip="$1"; ssh_port="$2"; banaction="$3"
  jail=/etc/fail2ban/jail.local
  backup_if_exists "$jail"
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

remove_malformed_override() {
  odir=/etc/systemd/system/fail2ban.service.d
  ofile="$odir/override.conf"
  if [ -f "$ofile" ]; then
    # If override contains suspicious patterns, back it up and remove it
    if grep -q -E '\. sock|fail2ban\.\s|fail2ban\.\.' "$ofile" 2>/dev/null || true; then
      mv "$ofile" "${ofile}.bak.$(TS)" || true
      echo "Backed up and removed malformed systemd override: $ofile"
    else
      echo "Existing systemd override left intact: $ofile"
    fi
  fi
}

validate_config() {
  if ! fail2ban-server -t >/tmp/fail2ban-config-test.log 2>&1; then
    echo "Config test failed:"
    sed -n '1,240p' /tmp/fail2ban-config-test.log || true
    return 1
  fi
  echo "Config OK"
  return 0
}

systemd_start_and_check() {
  systemctl daemon-reload || true
  systemctl enable --now fail2ban || true

  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if fail2ban-client ping >/dev/null 2>&1; then
      echo "Fail2Ban running (systemd)"
      return 0
    fi
    sleep 1
  done
  return 1
}

daemon_start_fallback() {
  echo "Attempting packaged daemon start: fail2ban-server start"
  if fail2ban-server start >/tmp/fail2ban-daemon-start.log 2>&1; then
    sleep 1
    if fail2ban-client ping >/dev/null 2>&1; then
      echo "Fail2Ban running after daemon start"
      return 0
    fi
  fi
  echo "Daemon start failed; tail /tmp/fail2ban-daemon-start.log:"
  tail -n 100 /tmp/fail2ban-daemon-start.log || true
  return 1
}

foreground_debug() {
  echo "Running foreground debug (8s) -> /tmp/fail2ban-debug.log"
  timeout 8s fail2ban-server -xf start &>/tmp/fail2ban-debug.log || true
  sed -n '1,240p' /tmp/fail2ban-debug.log || true
}

collect_full_diagnostics() {
  echo "==== systemctl status fail2ban ===="
  systemctl status fail2ban --no-pager || true
  echo "==== journalctl (fail2ban) last 200 lines ===="
  journalctl -u fail2ban -b --no-pager -n 200 || true
  echo "==== listing /run and /var/run ===="
  ls -lah /run/fail2ban /var/run/fail2ban || true
  echo "==== /etc/fail2ban/jail.local ===="
  sed -n '1,240p' /etc/fail2ban/jail.local || true
  echo "==== tail of persistent installer log ($PERSIST_LOG) ===="
  tail -n 200 "$PERSIST_LOG" || true
  echo "==== per-run tmp log ($TMP_LOG) ===="
  tail -n 200 "$TMP_LOG" || true
}

main() {
  require_root
  echo "Installer start: $(TS)"
  install_deps || true

  server_ip="$(detect_primary_ipv4)"
  ssh_port="$(detect_ssh_port)"
  banaction="$(detect_banaction)"
  echo "Detected: server_ip=${server_ip:-<none>}, ssh_port=${ssh_port:-ssh}, banaction=${banaction}"

  ensure_run_dirs
  remove_malformed_override
  write_jail_local "$server_ip" "$ssh_port" "$banaction"

  if ! validate_config; then
    echo "Validation failed; printing diagnostics"
    collect_full_diagnostics
    exit 1
  fi

  if systemd_start_and_check; then
    echo "Success: Fail2Ban running under systemd"
    echo "Installer log: $PERSIST_LOG"
    exit 0
  fi

  echo "Systemd start failed; attempting daemon fallback"
  if daemon_start_fallback; then
    echo "Success: Fail2Ban running after daemon fallback"
    echo "Installer log: $PERSIST_LOG"
    exit 0
  fi

  echo "Daemon fallback failed; running foreground debug"
  foreground_debug

  echo "Final diagnostics:"
  collect_full_diagnostics

  echo "Installer finished with failures. Inspect $PERSIST_LOG and $TMP_LOG"
  exit 1
}

main "$@"