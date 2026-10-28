# Demo: fresh VM to configured server

A script for recording or presenting the end-to-end demonstration. Each step
lists what to run and what to show. Allow about 15 minutes, most of it the
first deployment.

## Prerequisites

- Control machine with Python 3.10+ and `make deps` done
- [Multipass](https://multipass.run) (or any fresh Ubuntu 24.04 VM you can SSH into)
- An SSH key pair at `~/.ssh/id_ed25519`

## 1. Create a fresh VM

```bash
scripts/dev-vm.sh up
```

Show: a stock Ubuntu 24.04 cloud image with only your key added for `ubuntu`.

## 2. Show it is unconfigured

```bash
ssh ubuntu@<vm-ip> 'sudo ufw status; which docker psql; sudo ss -tlnp; sudo sshd -T | grep -E "passwordauth|permitroot"'
```

Show: UFW inactive, no Docker or PostgreSQL, only sshd and the local resolver
listening.

## 3. Provide secrets

```bash
scripts/init-vault.sh development
export ANSIBLE_VAULT_PASSWORD_FILE=~/.config/bastion/development.vault-pass
ansible-vault view ansible/inventories/development/group_vars/all/vault.yml
```

Show: generated passwords, encrypted at rest, never committed.

## 4. Bootstrap access

```bash
make bootstrap
```

Show: the admin user created as `ubuntu`, then the second play logging in
**as the admin** and confirming sudo. Access is proven before anything is
locked down.

## 5. Deploy

```bash
make deploy
```

Point out while it runs:

- the firewall role finishing before the ssh role;
- "Arm the automatic rollback", then "Confirm a new SSH login works", then "Disarm";
- the Docker daemon validated with `dockerd --validate` before restart;
- PostgreSQL handlers: validate, reload, restart only if needed;
- the Prometheus config checked by `promtool` before install;
- the summary at the end.

## 6. Verify

```bash
make verify
cat reports/verify-bastion-dev.md
```

Show: the report table, listening sockets, the firewall rules with their
`bastion:` comments, and the result line. The development inventory enables
27 checks, so a healthy server reports "27/27 checks passed".

## 7. Show working services

```bash
ssh -L 3000:127.0.0.1:3000 deploy@<vm-ip>
# browser: http://localhost:3000 (admin + vault password), Bastion -> Bastion host overview
```

```bash
ssh deploy@<vm-ip> 'docker compose -f /opt/bastion/monitoring/compose.yml ps; sudo -u postgres psql -l; sudo ufw status'
```

Also show that the old access path is closed:

```bash
ssh -o PasswordAuthentication=yes -o PubkeyAuthentication=no deploy@<vm-ip>   # refused: publickey only
ssh ubuntu@<vm-ip>                                                              # refused: not in sshusers
```

## 8. Run it again

```bash
make idempotency
```

Show: every task `ok`, the recap `changed=0`, and "Idempotency check passed".
This is the central claim of the project: the automation describes a state,
not a sequence of steps.

## Cleanup

```bash
scripts/dev-vm.sh down
```

## Evidence to capture for the README

| Screenshot | Step |
|---|---|
| Unconfigured VM (`ufw status`, `ss -tlnp`) | 2 |
| Deployment recap | 5 |
| Verification report | 6 |
| Grafana "Bastion host overview" dashboard | 7 |
| `docker compose ps` and `psql -l` | 7 |
| Idempotent second run with `changed=0` | 8 |

Save them under `docs/images/` and link them from the README's
"Screenshots / Demo" section.
