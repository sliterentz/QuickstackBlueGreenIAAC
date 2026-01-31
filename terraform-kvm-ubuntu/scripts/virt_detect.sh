#!/usr/bin/env bash
set -euo pipefail

virt_type="qemu"
if [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
  virt_type="kvm"
fi

emulator=""
if [[ -x /usr/libexec/qemu-kvm ]]; then
  emulator="/usr/libexec/qemu-kvm"
elif command -v qemu-system-x86_64 >/dev/null 2>&1; then
  emulator="$(command -v qemu-system-x86_64)"
fi

escape_json() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

printf '{"virt_type":"%s","emulator":"%s"}\n' "$(escape_json "$virt_type")" "$(escape_json "$emulator")"
