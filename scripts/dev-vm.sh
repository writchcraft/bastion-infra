#!/usr/bin/env bash
# Disposable Ubuntu 24.04 VM for the development inventory, using Multipass
# (https://multipass.run). The VM is a stock Ubuntu cloud image: the same
# starting point as a fresh cloud server.
#
# Usage: scripts/dev-vm.sh up|down|status
#
#   up      create the VM, authorise your public key for the "ubuntu" user,
#           record its address in the development inventory, trust its host key
#   down    delete the VM and its inventory address
#   status  show the VM
set -euo pipefail

name="${BASTION_VM_NAME:-bastion-dev}"
public_key="${BASTION_PUBLIC_KEY:-$HOME/.ssh/id_ed25519.pub}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
host_vars="$root/ansible/inventories/development/host_vars/bastion-dev.yml"

die() { echo "error: $*" >&2; exit 1; }
command -v multipass >/dev/null || die "multipass is not installed"

vm_ip() {
    multipass info "$name" --format json \
        | python3 -c 'import json, sys; info = json.load(sys.stdin)["info"]; print(next(iter(info.values()))["ipv4"][0])'
}

case "${1:-}" in
    up)
        [[ -f "$public_key" ]] || die "$public_key not found (set BASTION_PUBLIC_KEY)"
        # Multipass may only read files in the home directory.
        cloud_init="$(mktemp "$HOME/.bastion-cloud-init.XXXXXX")"
        trap 'rm -f "$cloud_init"' EXIT
        printf '#cloud-config\nssh_authorized_keys:\n  - %s\n' "$(cat "$public_key")" > "$cloud_init"

        multipass launch 24.04 --name "$name" --cpus 2 --memory 4G --disk 20G --cloud-init "$cloud_init"
        ip="$(vm_ip)"

        mkdir -p "$(dirname "$host_vars")"
        printf -- '---\n# Written by scripts/dev-vm.sh\nansible_host: %s\n' "$ip" > "$host_vars"

        # A brand-new local VM: accept its host key once, replacing any stale
        # entry left by a previous VM on the same address.
        ssh-keygen -R "$ip" >/dev/null 2>&1 || true
        ssh-keyscan -t ed25519 "$ip" 2>/dev/null >> "$HOME/.ssh/known_hosts"

        echo
        echo "VM $name is at $ip. Next: make bootstrap && make deploy"
        ;;
    down)
        multipass delete --purge "$name"
        rm -f "$host_vars"
        ;;
    status)
        multipass info "$name"
        ;;
    *)
        die "usage: $0 up|down|status"
        ;;
esac
