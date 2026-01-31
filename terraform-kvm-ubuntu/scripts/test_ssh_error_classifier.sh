#!/bin/bash
set -euo pipefail

classify_ssh_error() {
  local msg="${1:-}"
  msg=$(echo "$msg" | tr -d '\r')
  if echo "$msg" | grep -qiE "REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed"; then
    echo "host_key_verification_failed"
  elif echo "$msg" | grep -qiE "Permission denied"; then
    echo "permission_denied"
  elif echo "$msg" | grep -qiE "No route to host|Network is unreachable|Destination Host Unreachable"; then
    echo "network_unreachable"
  elif echo "$msg" | grep -qiE "Connection refused"; then
    echo "connection_refused"
  elif echo "$msg" | grep -qiE "Connection timed out|Operation timed out|timed out"; then
    echo "connection_timeout"
  elif echo "$msg" | grep -qiE "Could not resolve hostname|Temporary failure in name resolution|Name or service not known"; then
    echo "dns_failure"
  elif echo "$msg" | grep -qiE "No such file or directory"; then
    echo "file_missing"
  elif echo "$msg" | grep -qiE "bad permissions"; then
    echo "key_bad_permissions"
  else
    echo "unknown"
  fi
}

failures=0

run_case() {
  local expected="$1"
  local input="$2"
  local got=""
  got=$(classify_ssh_error "$input")
  if [ "$got" != "$expected" ]; then
    echo "FAIL expected=$expected got=$got input=$(echo "$input" | head -1)"
    failures=$((failures + 1))
  else
    echo "PASS $expected"
  fi
}

run_case "permission_denied" "Permission denied (publickey)."
run_case "host_key_verification_failed" "Host key verification failed."
run_case "host_key_verification_failed" "REMOTE HOST IDENTIFICATION HAS CHANGED!"
run_case "network_unreachable" "No route to host"
run_case "network_unreachable" "Network is unreachable"
run_case "connection_refused" "ssh: connect to host 192.168.122.250 port 22: Connection refused"
run_case "connection_timeout" "ssh: connect to host 192.168.122.250 port 22: Connection timed out"
run_case "dns_failure" "ssh: Could not resolve hostname example.local: Name or service not known"
run_case "file_missing" "no such file or directory"
run_case "key_bad_permissions" "Bad permissions. Try removing permissions for user: ..."
run_case "unknown" "kex_exchange_identification: read: Connection reset by peer"

if [ "$failures" -gt 0 ]; then
  echo "FAILED ($failures)"
  exit 1
fi

echo "OK"
