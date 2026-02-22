#!/bin/bash
set -euo pipefail

if ! command -v systemctl >/dev/null 2>&1; then
  echo "ERROR: systemctl tidak tersedia. Pastikan WSL menggunakan systemd."
  exit 1
fi

if [ "$(systemctl is-system-running 2>/dev/null || true)" = "" ]; then
  echo "ERROR: systemd tidak berjalan."
  exit 1
fi

service_name="sshd"
if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "ssh.service"; then
  service_name="ssh"
fi

echo "Detected service: $service_name"

if ! rpm -q openssh-server >/dev/null 2>&1; then
  echo "openssh-server belum terinstall. Install dengan:"
  echo "  sudo dnf install -y openssh-server"
  exit 1
fi

echo "Validating sshd config..."
if sudo /usr/sbin/sshd -t -f /etc/ssh/sshd_config 2>/dev/null; then
  echo "OK: sshd_config valid."
else
  echo "WARN: sshd_config tidak valid. Menampilkan error:"
  sudo /usr/sbin/sshd -t -f /etc/ssh/sshd_config 2>&1 | head -n 20 || true

  if sudo grep -nE '^[[:space:]]*AllowUser([[:space:]]|$)' /etc/ssh/sshd_config >/dev/null 2>&1; then
    ts="$(date +%Y%m%d-%H%M%S)"
    backup="/etc/ssh/sshd_config.backup-$ts"
    echo "Fixing directive AllowUser -> AllowUsers (backup: $backup)"
    sudo cp -a /etc/ssh/sshd_config "$backup"
    sudo sed -i -E 's/^([[:space:]]*)AllowUser([[:space:]]+.*)?$/\\1AllowUsers\\2/' /etc/ssh/sshd_config
  fi

  echo "Re-validating sshd config..."
  sudo /usr/sbin/sshd -t -f /etc/ssh/sshd_config
  echo "OK: sshd_config valid setelah perbaikan."
fi

echo "Restarting $service_name..."
sudo systemctl restart "$service_name"
sudo systemctl status "$service_name" --no-pager -l | sed -n '1,25p' || true

echo "Enabling autostart..."
sudo systemctl enable "$service_name" >/dev/null 2>&1 || true

echo "Listening check (port 22):"
if command -v ss >/dev/null 2>&1; then
  sudo ss -lntp | grep -E '(:22[[:space:]]|:22$)' || true
else
  sudo lsof -iTCP:22 -sTCP:LISTEN -nP || true
fi

echo "Done."
