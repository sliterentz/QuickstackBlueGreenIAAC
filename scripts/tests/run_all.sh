#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

tests=(
  "$SCRIPT_DIR/test_libvirt_domain_drift.sh"
  "$SCRIPT_DIR/test_deploy_optimized_unit.sh"
  "$SCRIPT_DIR/test_n8n_tf_settings.sh"
  "$SCRIPT_DIR/test_terraform_kvm_summary_no_bc.sh"
  "$PROJECT_ROOT/terraform-kvm-ubuntu/scripts/test_ssh_error_classifier.sh"
)

failures=0

for t in "${tests[@]}"; do
  if [[ ! -f "$t" ]]; then
    echo "SKIP $t"
    continue
  fi
  chmod +x "$t" 2>/dev/null || true
  echo "RUN  $t"
  if "$t"; then
    echo "PASS $t"
  else
    echo "FAIL $t"
    failures=$((failures + 1))
  fi
done

if [[ "$failures" -gt 0 ]]; then
  echo "FAILED ($failures)"
  exit 1
fi

echo "OK"
