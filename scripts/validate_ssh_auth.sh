#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_TFVARS="${PROJECT_ROOT}/terraform.tfvars"
LOG_DIR="${PROJECT_ROOT}/logs"
LOG_FILE="${LOG_DIR}/.ssh_auth_validation.log"
KNOWN_HOSTS_FILE="${HOME}/.ssh/known_hosts"

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"

timestamp() { date +"%F %T"; }
log() { printf '%s %s\n' "$(timestamp)" "$*" | tee -a "$LOG_FILE" >&2; }

expand_home() {
  local p="$1"
  if [[ "$p" == "~/"* ]]; then
    echo "${HOME}/${p:2}"
  else
    echo "$p"
  fi
}

parse_tfvars_json() {
  local tfvars_path="$1"
  python3 - "$tfvars_path" <<'PY'
import json, re, sys

path = sys.argv[1]
text = open(path, "r", encoding="utf-8").read()

def str_var(name, default=""):
    m = re.search(rf'(?m)^[ \t]*{re.escape(name)}[ \t]*=[ \t]*"([^"]*)"', text)
    return m.group(1) if m else default

def int_var(name, default=0):
    m = re.search(rf'(?m)^[ \t]*{re.escape(name)}[ \t]*=[ \t]*([0-9]+)', text)
    return int(m.group(1)) if m else default

def list_str_var(name):
    m = re.search(rf'(?ms)^[ \t]*{re.escape(name)}[ \t]*=[ \t]*\[(.*?)\]', text)
    if not m:
        return []
    inner = m.group(1)
    return re.findall(r'"([^"]+)"', inner)

out = {
    "ssh_username": str_var("ssh_username", "ubuntu"),
    "ssh_private_key_path": str_var("ssh_private_key_path", "~/.ssh/id_rsa"),
    "server_ips": list_str_var("server_ips"),
    "worker_n8n_count": int_var("worker_n8n_count", 0),
    "worker_n8n_ip_start": str_var("worker_n8n_ip_start", ""),
}

print(json.dumps(out))
PY
}

compute_worker_ips() {
  local cidr="$1"
  local count="$2"
  python3 - "$cidr" "$count" <<'PY'
import ipaddress, sys
cidr = sys.argv[1]
count = int(sys.argv[2])
if not cidr or count <= 0:
    sys.exit(0)
base_ip = ipaddress.ip_interface(cidr).ip
for i in range(count):
    print(str(ipaddress.ip_address(int(base_ip) + i)))
PY
}

fix_known_hosts_for_ip() {
  local ip="$1"
  mkdir -p "$(dirname "$KNOWN_HOSTS_FILE")"
  touch "$KNOWN_HOSTS_FILE"

  ssh-keygen -R "$ip" -f "$KNOWN_HOSTS_FILE" >/dev/null 2>&1 || true
  ssh-keyscan -T 5 -H "$ip" >>"$KNOWN_HOSTS_FILE" 2>/dev/null || true
}

check_private_key() {
  local key_path="$1"

  if [[ ! -f "$key_path" ]]; then
    log "ERROR: SSH private key tidak ditemukan: $key_path"
    return 1
  fi

  local perms
  perms="$(stat -c %a "$key_path" 2>/dev/null || echo "")"
  if [[ -n "$perms" && "$perms" != "600" && "$perms" != "400" ]]; then
    log "WARN: Permission private key tidak aman ($perms). Mengatur ke 600: $key_path"
    chmod 600 "$key_path" 2>/dev/null || true
  fi

  if ! ssh-keygen -y -f "$key_path" >/dev/null 2>&1; then
    log "ERROR: File bukan private key yang valid (atau membutuhkan passphrase): $key_path"
    return 1
  fi

  return 0
}

ssh_probe() {
  local ip="$1"
  local user="$2"
  local key_path="$3"
  local strict="$4"

  ssh \
    -F /dev/null \
    -i "$key_path" \
    -o BatchMode=yes \
    -o ConnectTimeout=10 \
    -o StrictHostKeyChecking="$strict" \
    -o UserKnownHostsFile="$KNOWN_HOSTS_FILE" \
    "$user@$ip" "echo OK" 2>&1
}

TFVARS_PATH="$DEFAULT_TFVARS"
USER_OVERRIDE=""
KEY_OVERRIDE=""
IPS_OVERRIDE=""
FIX_KNOWN_HOSTS="auto"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tfvars)
      TFVARS_PATH="$2"
      shift 2
      ;;
    --user)
      USER_OVERRIDE="$2"
      shift 2
      ;;
    --key)
      KEY_OVERRIDE="$2"
      shift 2
      ;;
    --ips)
      IPS_OVERRIDE="$2"
      shift 2
      ;;
    --fix-known-hosts)
      FIX_KNOWN_HOSTS="true"
      shift 1
      ;;
    --no-fix-known-hosts)
      FIX_KNOWN_HOSTS="false"
      shift 1
      ;;
    *)
      log "ERROR: Argumen tidak dikenal: $1"
      exit 2
      ;;
  esac
done

if [[ ! -f "$TFVARS_PATH" ]]; then
  log "ERROR: tfvars tidak ditemukan: $TFVARS_PATH"
  exit 1
fi

cfg_json="$(parse_tfvars_json "$TFVARS_PATH")"
ssh_user="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["ssh_username"])' <<<"$cfg_json")"
ssh_key_path="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["ssh_private_key_path"])' <<<"$cfg_json")"
server_ips="$(python3 -c 'import json,sys;print(" ".join(json.load(sys.stdin)["server_ips"]))' <<<"$cfg_json")"
worker_count="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["worker_n8n_count"])' <<<"$cfg_json")"
worker_start="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["worker_n8n_ip_start"])' <<<"$cfg_json")"

if [[ -n "$USER_OVERRIDE" ]]; then
  ssh_user="$USER_OVERRIDE"
fi

if [[ -n "$KEY_OVERRIDE" ]]; then
  ssh_key_path="$KEY_OVERRIDE"
fi

ssh_key_path="$(expand_home "$ssh_key_path")"

ips=()
if [[ -n "$IPS_OVERRIDE" ]]; then
  read -r -a ips <<<"$IPS_OVERRIDE"
else
  if [[ -n "$server_ips" ]]; then
    read -r -a ips <<<"$server_ips"
  fi
  if [[ -n "$worker_start" && "$worker_count" != "0" ]]; then
    while read -r ip; do
      [[ -n "$ip" ]] && ips+=("$ip")
    done < <(compute_worker_ips "$worker_start" "$worker_count")
  fi
fi

if [[ ${#ips[@]} -eq 0 ]]; then
  log "ERROR: Tidak ada target IP untuk divalidasi"
  exit 1
fi

log "INFO: tfvars=$TFVARS_PATH"
log "INFO: user=$ssh_user"
log "INFO: key=$ssh_key_path"
log "INFO: targets=${ips[*]}"

check_private_key "$ssh_key_path"

overall_ok="true"

for ip in "${ips[@]}"; do
  log "INFO: Validating SSH to $ssh_user@$ip"

  out="$(ssh_probe "$ip" "$ssh_user" "$ssh_key_path" "yes" || true)"
  if echo "$out" | grep -q "^OK$"; then
    log "OK: SSH berhasil: $ssh_user@$ip"
    continue
  fi

  if echo "$out" | grep -qiE "REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed"; then
    log "WARN: Host key mismatch untuk $ip"
    if [[ "$FIX_KNOWN_HOSTS" == "auto" || "$FIX_KNOWN_HOSTS" == "true" ]]; then
      log "INFO: Memperbarui known_hosts untuk $ip"
      fix_known_hosts_for_ip "$ip"
      out2="$(ssh_probe "$ip" "$ssh_user" "$ssh_key_path" "yes" || true)"
      if echo "$out2" | grep -q "^OK$"; then
        log "OK: SSH berhasil setelah refresh known_hosts: $ssh_user@$ip"
        continue
      fi
      out="$out2"
    fi
  elif echo "$out" | grep -qiE "are you sure you want to continue connecting"; then
    if [[ "$FIX_KNOWN_HOSTS" == "auto" || "$FIX_KNOWN_HOSTS" == "true" ]]; then
      log "INFO: Menambahkan host key baru untuk $ip (accept-new)"
      out2="$(ssh_probe "$ip" "$ssh_user" "$ssh_key_path" "accept-new" || true)"
      if echo "$out2" | grep -q "^OK$"; then
        log "OK: SSH berhasil setelah accept-new: $ssh_user@$ip"
        continue
      fi
      out="$out2"
    fi
  fi

  if echo "$out" | grep -qiE "Permission denied \\(publickey\\)"; then
    log "ERROR: Autentikasi public key ditolak oleh server: $ssh_user@$ip"
    overall_ok="false"
    continue
  fi

  if echo "$out" | grep -qiE "No route to host|Connection timed out|Connection refused"; then
    log "ERROR: Koneksi SSH gagal ke $ip: $(echo "$out" | tail -n 1)"
    overall_ok="false"
    continue
  fi

  log "ERROR: SSH gagal untuk $ssh_user@$ip"
  log "ERROR: Output: $(echo "$out" | tr '\n' ' ' | sed 's/[[:space:]]\\+/ /g')"
  overall_ok="false"
done

if [[ "$overall_ok" == "true" ]]; then
  log "SUCCESS: Semua target SSH tervalidasi"
  exit 0
fi

log "FAILED: Ada target SSH yang gagal tervalidasi. Lihat log: $LOG_FILE"
exit 1
