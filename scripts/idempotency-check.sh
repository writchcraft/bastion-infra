#!/usr/bin/env bash
# Runs a playbook and fails if any task or handler reports "changed".
# Run it against a server that has already been configured once.
#
# Usage (from the ansible/ directory):
#   ../scripts/idempotency-check.sh -i inventories/development playbooks/server.yml
set -euo pipefail

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

ANSIBLE_FORCE_COLOR=0 ansible-playbook "$@" | tee "$log"

changed_tasks="$(awk '/^(TASK|RUNNING HANDLER) \[/ { task = $0 } /^changed:/ { print task }' "$log" | sort -u)"

echo
if grep -Eq 'changed=[1-9]' "$log"; then
    echo "Idempotency check FAILED. These tasks reported changes on a repeat run:"
    echo "$changed_tasks"
    exit 1
fi
echo "Idempotency check passed: no task reported a change."
