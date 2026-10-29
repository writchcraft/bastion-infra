#!/usr/bin/env bash
# Proves the idempotency gate itself: it must pass a clean recap and fail on
# changes, a missing recap, or a failing playbook. Uses a stub ansible-playbook,
# so it needs no server.
#
# Usage: scripts/test-idempotency-check.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The stub prints whatever STUB_OUTPUT holds and exits with STUB_RC.
cat > "$work/ansible-playbook" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$STUB_OUTPUT"
exit "${STUB_RC:-0}"
STUB
chmod +x "$work/ansible-playbook"

failures=0
expect() { # <name> <expected exit: 0|nonzero> <rc of stub> <stub output>
    local name="$1" expected="$2" rc="$3" output="$4" actual=0
    PATH="$work:$PATH" STUB_RC="$rc" STUB_OUTPUT="$output" \
        "$root/scripts/idempotency-check.sh" site.yml > /dev/null 2>&1 || actual=$?
    if { [[ "$expected" == 0 && "$actual" -eq 0 ]] || [[ "$expected" == nonzero && "$actual" -ne 0 ]]; }; then
        echo "ok   - $name"
    else
        echo "FAIL - $name (exit $actual)"
        failures=$((failures + 1))
    fi
}

clean=$'TASK [x : y] ***\nok: [h]\n\nPLAY RECAP ***\nh                          : ok=10   changed=0    unreachable=0    failed=0    skipped=2    rescued=0    ignored=0'
dirty=$'TASK [x : y] ***\nchanged: [h]\n\nPLAY RECAP ***\nh                          : ok=10   changed=1    unreachable=0    failed=0    skipped=2    rescued=0    ignored=0'
mixed=$'PLAY RECAP ***\na                          : ok=10   changed=0    unreachable=0    failed=0\nb                          : ok=10   changed=3    unreachable=0    failed=0'

expect "clean recap passes"            0       0 "$clean"
expect "changed=1 fails"               nonzero 0 "$dirty"
expect "one changed host of two fails" nonzero 0 "$mixed"
expect "no recap fails"                nonzero 0 "skipping: no hosts matched"
expect "playbook failure fails"        nonzero 2 "$clean"

exit "$failures"
