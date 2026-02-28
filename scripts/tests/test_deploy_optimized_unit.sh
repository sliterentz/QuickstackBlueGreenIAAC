#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PROJECT_ROOT/scripts/deploy_optimized.sh"

failures=0

assert_eq() {
  local expected="$1"
  local got="$2"
  local name="$3"
  if [[ "$got" != "$expected" ]]; then
    echo "FAIL $name expected=$expected got=$got"
    failures=$((failures + 1))
  else
    echo "PASS $name"
  fi
}

assert_true() {
  local name="$1"
  shift
  if "$@"; then
    echo "PASS $name"
  else
    echo "FAIL $name"
    failures=$((failures + 1))
  fi
}

assert_false() {
  local name="$1"
  shift
  if "$@"; then
    echo "FAIL $name"
    failures=$((failures + 1))
  else
    echo "PASS $name"
  fi
}

make_tmpfile() {
  mktemp "${TMPDIR:-/tmp}/deploy_optimized_test.XXXXXX"
}

tmp="$(make_tmpfile)"
printf "%s\n" "timeout while waiting for state to become 'EXISTS'" >"$tmp"
assert_eq "volume_timeout" "$(classify_terraform_apply_failure "$tmp")" "classify_volume_timeout"
rm -f "$tmp"

tmp="$(make_tmpfile)"
printf "%s\n" "libvirt_cloudinit_disk.commoninit exists already" >"$tmp"
assert_eq "cloudinit_exists" "$(classify_terraform_apply_failure "$tmp")" "classify_cloudinit_exists"
rm -f "$tmp"

tmp="$(make_tmpfile)"
printf "%s\n" "Error: error while starting the creation of CloudInit's ISO image: exec: \"mkisofs\": executable file not found in \$PATH" >"$tmp"
assert_eq "mkisofs_missing" "$(classify_terraform_apply_failure "$tmp")" "classify_mkisofs_missing"
rm -f "$tmp"

tmp="$(make_tmpfile)"
cat >"$tmp" <<'EOF'
qemu-system-x86_64: -blockdev {"driver":"file","filename":"/var/lib/libvirt/images/k3s_infra_pool/ubuntu-base-img-k3s-master-01.qcow2"}: Could not open '/var/lib/libvirt/images/k3s_infra_pool/ubuntu-base-img-k3s-master-01.qcow2': Permission denied
EOF
assert_eq "libvirt_image_permission_denied" "$(classify_terraform_apply_failure "$tmp")" "classify_libvirt_image_permission_denied"
rm -f "$tmp"

tmp="$(make_tmpfile)"
printf "%s\n" "Error: error defining libvirt domain: operation failed: domain 'k3s-master-01' already exists with uuid 488e498a" >"$tmp"
assert_eq "libvirt_domain_exists" "$(classify_terraform_apply_failure "$tmp")" "classify_libvirt_domain_exists"
rm -f "$tmp"

tmp="$(make_tmpfile)"
printf "%s\n" "Apply failed with 1 conflict: conflict with \"kubectl-set\" using apps/v1" >"$tmp"
assert_eq "k8s_ssa_conflict" "$(classify_terraform_apply_failure "$tmp")" "classify_k8s_ssa_conflict"
rm -f "$tmp"

tmp="$(make_tmpfile)"
printf "%s\n" "no domain with matching uuid" >"$tmp"
assert_eq "libvirt_domain_uuid_stale" "$(classify_terraform_apply_failure "$tmp")" "classify_libvirt_uuid_stale"
rm -f "$tmp"

tmp="$(make_tmpfile)"
printf "%s\n" "already exists" >"$tmp"
assert_eq "resource_exists" "$(classify_terraform_apply_failure "$tmp")" "classify_resource_exists"
rm -f "$tmp"

tmp="$(make_tmpfile)"
printf "%s\n" "some other error" >"$tmp"
assert_eq "unknown" "$(classify_terraform_apply_failure "$tmp")" "classify_unknown"
rm -f "$tmp"

tmp="$(make_tmpfile)"
cat >"$tmp" <<'EOF'
apiVersion: v1
clusters:
- cluster:
    server: https://127.0.0.1:6443
  name: default
EOF
assert_true "kubeconfig_is_dummy_true" kubeconfig_is_dummy "$tmp"
rm -f "$tmp"

tmp="$(make_tmpfile)"
cat >"$tmp" <<'EOF'
apiVersion: v1
clusters:
- cluster:
    server: https://192.168.122.250:6443
  name: default
EOF
assert_false "kubeconfig_is_dummy_false" kubeconfig_is_dummy "$tmp"
assert_eq "https://192.168.122.250:6443" "$(kubeconfig_server_url "$tmp")" "kubeconfig_server_url"
rm -f "$tmp"

tmp="$(make_tmpfile)"
printf "%s\n" "apiVersion: v1" >"$tmp"
assert_eq "" "$(kubeconfig_server_url "$tmp")" "kubeconfig_server_url_missing"
rm -f "$tmp"

assert_eq "600" "$(parse_duration_seconds "600")" "parse_duration_seconds_plain"
assert_eq "600" "$(parse_duration_seconds "600s")" "parse_duration_seconds_s"
assert_eq "120" "$(parse_duration_seconds "2m")" "parse_duration_seconds_m"
assert_eq "7200" "$(parse_duration_seconds "2h")" "parse_duration_seconds_h"

parse_arguments --dry-run --no-backup --force
assert_eq "true" "${DRY_RUN}" "parse_arguments_sets_dry_run"
assert_eq "true" "${SKIP_BACKUP}" "parse_arguments_sets_no_backup"
assert_eq "true" "${FORCE_MODE}" "parse_arguments_sets_force"

test_containerd_reserved_name_true() { log_contains_containerd_name_reservation_issue <<< 'Error: failed to reserve container name foo is reserved for bar'; }
test_containerd_reserved_name_false() { log_contains_containerd_name_reservation_issue <<< 'Normal Pulled container image already present'; }
assert_true "detect_containerd_reserved_name_true" test_containerd_reserved_name_true
assert_false "detect_containerd_reserved_name_false" test_containerd_reserved_name_false

tmp="$(make_tmpfile)"
cat >"$tmp" <<'EOF'
n8n-main-aaa  0/1  ContainerCreating  0  1m  10.42.0.10  k3s-master-01  <none>  <none>
n8n-worker-bbb  0/1  ContainerCreating  0  1m  10.42.0.11  n8n-worker-1  <none>  <none>
n8n-worker-ccc  0/1  ContainerCreating  0  1m  10.42.0.12  n8n-worker-1  <none>  <none>
EOF
got_counts="$(cat "$tmp" | pod_nodes_from_kubectl_wide | summarize_node_counts | tr '\n' ';' )"
assert_true "pod_distribution_contains_master" bash -c 'echo "$0" | grep -q "k3s-master-01 1;"' "$got_counts"
assert_true "pod_distribution_contains_worker" bash -c 'echo "$0" | grep -q "n8n-worker-1 2;"' "$got_counts"
rm -f "$tmp"

tmp="$(make_tmpfile)"
cat >"$tmp" <<'EOF'
n8n-main-aaa  0/1  ContainerCreating  0  1m
n8n-main-bbb  1/1  Running            0  1m
n8n-main-ccc  2/2  Running            0  1m
n8n-main-ddd  1/2  Running            0  1m
EOF
not_ready="$(cat "$tmp" | pods_not_fully_ready_from_kubectl_get_noheaders | tr '\n' ';')"
assert_true "pods_not_fully_ready_contains_aaa" bash -c 'echo "$0" | grep -q "n8n-main-aaa;"' "$not_ready"
assert_true "pods_not_fully_ready_contains_ddd" bash -c 'echo "$0" | grep -q "n8n-main-ddd;"' "$not_ready"
assert_false "pods_not_fully_ready_excludes_bbb" bash -c 'echo "$0" | grep -q "n8n-main-bbb;"' "$not_ready"
assert_false "pods_not_fully_ready_excludes_ccc" bash -c 'echo "$0" | grep -q "n8n-main-ccc;"' "$not_ready"
rm -f "$tmp"

if [[ "$failures" -gt 0 ]]; then
  echo "FAILED ($failures)"
  exit 1
fi

echo "OK"
