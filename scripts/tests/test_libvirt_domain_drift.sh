#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_SRC="${PROJECT_ROOT}/terraform.tfstate"
VAR_FILE="${PROJECT_ROOT}/terraform.tfvars"

MODE="${1:-check}"

if [[ ! -f "$STATE_SRC" ]]; then
  echo "terraform.tfstate not found: $STATE_SRC" >&2
  exit 1
fi

TMP_STATE="$(mktemp -t quickstack-state-XXXXXX.json)"
cp -f "$STATE_SRC" "$TMP_STATE"

cleanup() {
  rm -f "$TMP_STATE"
}
trap cleanup EXIT

random_uuid() {
  python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
}

mutate_state_domain_id() {
  local addr="$1"
  local new_id="$2"

  STATE_PATH="$TMP_STATE" ADDR="$addr" NEW_ID="$new_id" python3 - <<'PY'
import json
import os

state_path = os.environ["STATE_PATH"]
addr = os.environ["ADDR"]
new_id = os.environ["NEW_ID"]

with open(state_path, 'r', encoding='utf-8') as f:
    data = json.load(f)

resources = data.get('resources', [])
for r in resources:
    module = r.get('module')
    rtype = r.get('type')
    rname = r.get('name')
    if module and rtype and rname:
        full_addr = f"{module}.{rtype}.{rname}"
        if full_addr != addr:
            continue
        for inst in r.get('instances', []):
            attrs = inst.get('attributes', {})
            if 'id' in attrs:
                attrs['id'] = new_id
                inst['attributes'] = attrs
        r['instances'] = r.get('instances', [])

with open(state_path, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2)
PY
}

list_domain_addrs() {
  terraform state list -state="$TMP_STATE" 2>/dev/null | grep -E 'libvirt_domain\.ubuntu_vm$' || true
}

state_attr() {
  local addr="$1" key="$2"
  terraform state show -no-color -state="$TMP_STATE" "$addr" 2>/dev/null | awk -F'=' -v k="$key" '$1 ~ "^[[:space:]]*"k"[[:space:]]*$" {gsub(/[[:space:]]|"|\r/,"",$2); print $2; exit}'
}

check_domain_sync() {
  local addrs
  addrs="$(list_domain_addrs)"
  if [[ -z "$addrs" ]]; then
    echo "No libvirt_domain resources found in state."
    return 0
  fi

  local ok=0
  local bad=0
  while read -r addr; do
    [[ -z "$addr" ]] && continue
    local name id
    name="$(state_attr "$addr" name || true)"
    id="$(state_attr "$addr" id || true)"

    if [[ -n "$id" ]] && virsh -c qemu:///system dominfo "$id" >/dev/null 2>&1; then
      echo "OK   $addr id=$id name=$name"
      ok=$((ok+1))
      continue
    fi

    if [[ -n "$name" ]] && virsh -c qemu:///system dominfo "$name" >/dev/null 2>&1; then
      echo "DRIFT_UUID $addr id=$id name=$name"
      bad=$((bad+1))
      continue
    fi

    echo "MISSING $addr id=$id name=$name"
    bad=$((bad+1))
  done <<< "$addrs"

  echo "Summary: ok=$ok bad=$bad"
  [[ $bad -eq 0 ]]
}

simulate_uuid_drift() {
  local addr
  addr="$(list_domain_addrs | head -n 1 || true)"
  if [[ -z "$addr" ]]; then
    echo "No domain address found to mutate" >&2
    exit 1
  fi

  local target_addr
  target_addr="$addr"

  local name
  name="$(state_attr "$addr" name || true)"
  if [[ -z "$name" ]]; then
    echo "Could not read name for $addr" >&2
    exit 1
  fi

  local bogus
  bogus="$(random_uuid)"
  echo "Mutating $addr id -> $bogus (domain exists by name: $name)"
  mutate_state_domain_id "$addr" "$bogus"

  echo "Running drift check on mutated state..."
  check_domain_sync || true

  echo "Attempting to remove drifted domain from mutated state (safe)..."
  terraform state rm -state="$TMP_STATE" "$target_addr" >/dev/null
  echo "Removed: $target_addr"
}

case "$MODE" in
  check)
    check_domain_sync
    ;;
  simulate-uuid-drift)
    simulate_uuid_drift
    ;;
  *)
    echo "Usage: $0 {check|simulate-uuid-drift}" >&2
    exit 2
    ;;
esac
