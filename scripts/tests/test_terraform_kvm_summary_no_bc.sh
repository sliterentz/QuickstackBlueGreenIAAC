#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

file="$PROJECT_ROOT/terraform-kvm-ubuntu/main.tf"

failures=0

assert_grep() {
  local pattern="$1"
  local name="$2"
  if grep -qE "$pattern" "$file"; then
    echo "PASS $name"
  else
    echo "FAIL $name pattern=$pattern"
    failures=$((failures + 1))
  fi
}

assert_not_grep() {
  local pattern="$1"
  local name="$2"
  if grep -qE "$pattern" "$file"; then
    echo "FAIL $name pattern=$pattern"
    failures=$((failures + 1))
  else
    echo "PASS $name"
  fi
}

assert_not_grep "\\| bc\\)" "deployment_summary_does_not_require_bc"
assert_grep "Disk Size: \\$\\(awk 'BEGIN \\{printf \"%\\.2f\", \\$\\{var\\.vm_disk_size\\} / 1024 / 1024 / 1024\\}'\\) GB" "deployment_summary_uses_awk"

if [[ "$failures" -gt 0 ]]; then
  echo "FAILED ($failures)"
  exit 1
fi

echo "OK"
