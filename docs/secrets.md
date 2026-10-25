# Secrets

Bastion uses **Ansible Vault**. It needs no extra infrastructure, works
offline, and keeps secrets next to the inventory they belong to.

## Rules

- Real secrets never enter this repository. `vault.yml` files are git-ignored,
  even though they are encrypted, because this is a public portfolio repository.
  In a private infrastructure repository the encrypted file would normally be
  committed.
- Only `vault.yml.example` files are tracked, and they contain fake values
  (`CHANGE_ME`, `REPLACE_ME`).
- The vault password lives outside the repository, by default in
  `~/.config/bastion/<inventory>.vault-pass` with mode 0600.
- SSH private keys are never stored anywhere in the project. The inventory
  references the operator's *public* key by path.
- Roles refuse placeholder values: `CHANGE_ME` passwords and `REPLACE_ME` keys
  or hashes fail validation before anything is changed.

## What belongs in the vault

| Variable | Used for |
|---|---|
| `vault_grafana_admin_password` | Grafana admin login (`monitoring_grafana_admin_password`) |
| `vault_postgres_<role>_password` | PostgreSQL login roles (`postgres_users[].password`) |
| `vault_<user>_password_hash` | sudo password for admins with `sudo_nopasswd: false` |
| API tokens, private environment data | anything that must not appear in plain text |

Configuration files reference vault values by name. The `vault_` prefix
makes it obvious where a value comes from:

```yaml
# group_vars/all/main.yml (plain text, reviewable)
monitoring_grafana_admin_password: "{{ vault_grafana_admin_password }}"

# group_vars/all/vault.yml (encrypted)
vault_grafana_admin_password: s0me-long-random-value
```

## Create a vault

The quickest path generates random passwords for every `CHANGE_ME`:

```bash
scripts/init-vault.sh development
export ANSIBLE_VAULT_PASSWORD_FILE=~/.config/bastion/development.vault-pass
```

By hand:

```bash
cd ansible/inventories/development/group_vars/all
cp vault.yml.example vault.yml
$EDITOR vault.yml
ansible-vault encrypt vault.yml
```

Generate a sudo password hash (from the `whois` package) with:

```bash
mkpasswd --method=sha-512
```

## Edit, view, rotate

```bash
ansible-vault edit ansible/inventories/development/group_vars/all/vault.yml
ansible-vault view ansible/inventories/development/group_vars/all/vault.yml
ansible-vault rekey ansible/inventories/development/group_vars/all/vault.yml   # new vault password
```

After changing a secret, rerun `make deploy`:

- PostgreSQL passwords are updated in place.
- The Grafana admin password is reset when the stored one no longer matches.

## Run playbooks with the vault

Either export a password file once per shell:

```bash
export ANSIBLE_VAULT_PASSWORD_FILE=~/.config/bastion/development.vault-pass
make deploy
```

or be prompted each time (the Makefile adds `--ask-vault-pass` when no
password file is configured):

```bash
cd ansible && ansible-playbook playbooks/server.yml --ask-vault-pass
```

## Keeping secrets out of logs

- Tasks that receive passwords use `no_log: true`.
- The Grafana credentials file is templated with `diff: false`, so
  `--diff` runs do not print it.
- The Grafana password reset passes the password on stdin, not as a
  command-line argument visible in the process list.
- CI generates a throw-away vault for each run with `scripts/init-vault.sh ci`.
