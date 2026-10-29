#!/usr/bin/env bash
# Runs a playbook and fails if any task or handler reports "changed".
# Run it against a server that has already been configured once.
#
# It also fails when the run produced no play recap at all (for example no
# hosts matched), because "nothing ran" is not proof of idempotency.
#
# Usage (from the ansible/ directory):
#   ../scripts/idempotency-check.sh -i inventories/development playbooks/server.yml
set -euo pipefail

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

ANSIBLE_FORCE_COLOR=0 ansible-playbook "$@" | tee "$log"

recap="$(grep -E '^[^ ]+ +: +ok=[0-9]+ +changed=[0-9]+' "$log" || true)"
changed_tasks="$(awk '/^(TASK|RUNNING HANDLER) \[/ { task = $0 } /^changed:/ { print task }' "$log" | sort -u)"

# On GitHub Actions the recap is shown on the run page, not only in the log.
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        echo "### Idempotency check (second deployment)"
        echo
        echo '```text'
        echo "${recap:-no play recap found}"
        echo '```'
    } >> "$GITHUB_STEP_SUMMARY"
fi

echo
if [[ -z "$recap" ]]; then
    echo "Idempotency check FAILED: the playbook produced no play recap, so nothing was proven."
    exit 1
fi
if grep -Eq 'changed=[1-9]' <<< "$recap"; then
    echo "Idempotency check FAILED. These tasks reported changes on a repeat run:"
    echo "$changed_tasks"
    exit 1
fi
echo "Idempotency check passed: no task reported a change."
