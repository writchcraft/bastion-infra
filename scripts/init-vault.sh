#!/usr/bin/env bash
# Creates the encrypted vault.yml for an inventory from its vault.yml.example,
# replacing every CHANGE_ME with a random 32-character password.
#
# Usage: scripts/init-vault.sh <inventory> [vault-password-file]
#
# The vault password file defaults to $ANSIBLE_VAULT_PASSWORD_FILE, or
# ~/.config/bastion/<inventory>.vault-pass, and is created if missing.
# It lives outside the repository and must never be committed.
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

[[ $# -ge 1 ]] || die "usage: $0 <inventory> [vault-password-file]"
inventory="$1"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
vars_dir="$root/ansible/inventories/$inventory/group_vars/all"
example="$vars_dir/vault.yml.example"
target="$vars_dir/vault.yml"
pass_file="${2:-${ANSIBLE_VAULT_PASSWORD_FILE:-$HOME/.config/bastion/$inventory.vault-pass}}"

[[ -f "$example" ]] || die "$example not found"
[[ -e "$target" ]] && die "$target already exists. Edit it with: ansible-vault edit $target"
command -v ansible-vault >/dev/null || die "ansible-vault not found (pip install -r requirements-dev.txt)"
command -v openssl >/dev/null || die "openssl not found"

random_password() {
    local raw
    raw="$(openssl rand -base64 48)"
    raw="${raw//[^A-Za-z0-9]/}"
    printf '%s' "${raw:0:32}"
}

if [[ ! -f "$pass_file" ]]; then
    mkdir -p "$(dirname "$pass_file")"
    (umask 077 && random_password > "$pass_file")
    echo "Created vault password file $pass_file (keep it safe; it is not in the repository)"
fi

# The plaintext only exists until encryption succeeds.
trap 'rm -f "$target"' ERR
(
    umask 077
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == *CHANGE_ME* ]]; then
            printf '%s\n' "${line//CHANGE_ME/$(random_password)}"
        else
            printf '%s\n' "$line"
        fi
    done < "$example" > "$target"
)
ansible-vault encrypt --vault-password-file "$pass_file" "$target" >/dev/null
trap - ERR

echo "Created encrypted $target"
if grep -q 'REPLACE_ME' "$example"; then
    echo "Some values need manual input (REPLACE_ME). Edit them with:"
    echo "  ansible-vault edit --vault-password-file $pass_file $target"
fi
echo "Use it with: export ANSIBLE_VAULT_PASSWORD_FILE=$pass_file"
