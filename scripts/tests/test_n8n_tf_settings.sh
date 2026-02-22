#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

file="$PROJECT_ROOT/n8n.tf"

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

assert_grep "^\\s*server_side_apply\\s*=\\s*true\\s*$" "server_side_apply_enabled"
assert_grep "^\\s*force_conflicts\\s*=\\s*true\\s*$" "force_conflicts_enabled"
assert_grep "^\\s*resource\\s+\"null_resource\"\\s+\"unlabel_master_n8n\"\\s*\\{" "unlabel_master_resource_exists"

if [[ "$failures" -gt 0 ]]; then
  echo "FAILED ($failures)"
  exit 1
fi

echo "OK"
