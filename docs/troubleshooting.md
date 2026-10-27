# Troubleshooting

Start with the verification report: `make verify` writes
`reports/verify-<host>.md` with every check, the listening sockets and the
firewall state. Then use the section for the failing area.

Useful everywhere:

```bash
ansible-playbook playbooks/server.yml -vvv               # full module arguments and results
ansible-playbook playbooks/server.yml --check --diff     # what would change, without changing it
ansible-playbook playbooks/server.yml --tags ssh         # one role at a time
ansible-playbook playbooks/server.yml --start-at-task "Write the SSH hardening drop-in"
journalctl -u <unit> -n 100 --no-pager                   # on the server
```

## Control machine

**`ansible.cfg` is ignored** (roles not found, wrong inventory). Run commands
from the `ansible/` directory, or use `make`. Ansible refuses to load
`ansible.cfg` from a world-writable directory, which is the default for
Windows drives mounted in WSL (`/mnt/c/...`). Clone the repository inside the
WSL filesystem (`~/src/bastion-infra`) instead.

**`couldn't resolve module/action 'community.…'`**: install the collections
with `make deps` (or `ansible-galaxy collection install -r requirements.yml`).

**`Attempting to decrypt but no vault secrets found`**: export
`ANSIBLE_VAULT_PASSWORD_FILE` or pass `--ask-vault-pass`. If `vault.yml` does
not exist yet, run `scripts/init-vault.sh <inventory>`.

**`… is undefined` for a `vault_` variable**: the inventory's `vault.yml` is
missing that key. Compare it with `vault.yml.example`.

## Connecting

**Host key verification failed.** `host_key_checking` is on by design. For a
VM you just created, accept the key once:

```bash
ssh-keyscan -t ed25519 <address> >> ~/.ssh/known_hosts
```

If the VM was recreated on the same address, remove the stale entry first with
`ssh-keygen -R <address>`.

**Bootstrap fails with `Permission denied (publickey)`.** The image account
does not have your key. Cloud images take a key at creation time (cloud-init
`ssh_authorized_keys`, or `scripts/dev-vm.sh`). For a password-only image, run
`ansible-playbook playbooks/bootstrap.yml -k -K` (requires `sshpass`).

**Bootstrap's second play fails.** The admin account was created but a new
session with your key did not work. Check that `bastion_admin_public_key_file`
(or the keys in `admin_users`) matches the private key your SSH agent offers.
Agents holding many keys can exceed `MaxAuthTries`; use `IdentitiesOnly yes`
with an explicit `IdentityFile`.

**`server.yml` stops at "Check this play will not lock itself out".** You are
connected as an account that the new policy would refuse, typically the image
user because bootstrap has not been run, or `ansible_user` is not set to the
admin. Run `bootstrap.yml` first and connect as `bastion_admin_user`.

## SSH

**"The new SSH configuration failed validation or a fresh login was refused".**
The ssh role already restored the previous configuration. On the server:

```bash
sudo journalctl -t bastion-sshd-rollback      # rollback history
sudo sshd -t                                  # current config validity
sudo sshd -T | grep -Ei 'port|passwordauth|allowgroups|permitroot'
```

The role re-checks the login with a new connection that bypasses Ansible's
multiplexing. If that check fails from the control machine (for example, a
corporate proxy or a different key in the agent), the change is rolled back
even though sshd itself was fine.

**Locked out anyway.** Wait `ssh_rollback_timeout` (5 minutes): the timer
restores the previous drop-in and reloads sshd. If the timer itself could not
run, use the provider's console, then:

```bash
sudo rm /etc/ssh/sshd_config.d/00-bastion.conf && sudo systemctl reload ssh
```

**`sshd -t` says "Missing privilege separation directory: /run/sshd".** sshd
under socket activation creates that directory only while running. The role
creates it before validating; if you validate by hand, run
`sudo mkdir -p /run/sshd` first.

**Changing the SSH port.**

1. Set `ssh_port: 2222` and run with `-e ssh_allow_port_change=true`. UFW opens 2222 and keeps the current port open; sshd moves; the role verifies a login on 2222.
2. Set `ansible_port: 2222` in the inventory.
3. Add the old port to `firewall_removed_rules` (`{port: 22, rule: limit}`) and deploy again.

## Firewall

```bash
sudo ufw status verbose          # rules, with "bastion:" comments
sudo ufw show added              # rules exactly as added
sudo journalctl -k | grep UFW    # blocked packets (logging: low)
```

**A service is reachable even though UFW denies it.** It is almost certainly
a Docker-published port; see "Docker and UFW" in [security.md](security.md).
`sudo ss -tlnp` shows which process owns the listener.

**fail2ban banned your address.**

```bash
sudo fail2ban-client status sshd
sudo fail2ban-client set sshd unbanip 198.51.100.7
```

Add your network to `fail2ban_ignore_networks` to prevent it recurring.

## Packages and repositories

**`Conflicting values set for option Signed-By`** for the Docker repository.
An older `docker.list` points at the same repository with a different key.
The docker role backs it up to `/var/backups/docker.list.bastion-backup` and
removes it; if another file under `/etc/apt/sources.list.d/` references
`download.docker.com`, remove it the same way.

**A reboot is pending.** Reported by the common role and as a warning in
verification. Reboot during a maintenance window (`sudo reboot`), or deploy once
with `-e common_reboot_if_required=true`.

**fail2ban fails to start on Ubuntu 24.04 with `No module named 'asynchat'`.**
This was a packaging bug in the original 24.04 release, fixed in
`noble-updates`. Make sure `common_upgrade_packages` is enabled, or run
`sudo apt-get install --only-upgrade fail2ban`.

## PostgreSQL

```bash
pg_lsclusters                                   # clusters, ports, status
sudo systemctl status postgresql@16-main
sudo journalctl -u postgresql@16-main -n 100
sudo -u postgres psql -c "SELECT * FROM pg_hba_file_rules WHERE error IS NOT NULL;"
sudo -u postgres psql -c "SELECT name, setting, pending_restart FROM pg_settings WHERE pending_restart;"
```

**"<config dir>/postgresql.conf was not found".** The role manages the default
`main` cluster that Debian packaging creates. If it was dropped or renamed,
creating or moving clusters is a deliberate operator action:
`sudo pg_createcluster 16 main --start`.

**Configuration change was not applied.** The handlers validate the new
settings, reload, and restart only if PostgreSQL reports `pending_restart`.
A validation failure lists the offending file and line.

### Backups and restore

```bash
sudo systemctl list-timers bastion-pg-backup.timer
sudo systemctl start bastion-pg-backup.service       # run a backup now
sudo journalctl -u bastion-pg-backup.service
sudo ls -l /var/backups/postgresql
```

Restore one database:

```bash
sudo -u postgres pg_restore --clean --if-exists --dbname=app /var/backups/postgresql/app_<stamp>.dump
```

Restore roles first on a new server:

```bash
sudo -u postgres psql -f /var/backups/postgresql/globals_<stamp>.sql
```

Backups are on the same disk as the database. Copying them off the host is
listed under future work.

## Docker and monitoring

```bash
cd /opt/bastion/monitoring
sudo docker compose ps
sudo docker compose logs --tail 100 prometheus grafana
curl -s http://127.0.0.1:9090/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, health, lastError}'
curl -s http://127.0.0.1:9100/metrics | head
```

**Prometheus config change was refused.** The template is checked with
`promtool check config` from the pinned image before it is installed, so a
broken config never reaches the running container. The task output shows
promtool's message.

**Scrape target down.** `lastError` in the targets API says why. node_exporter
listens on 127.0.0.1:9100 (`/etc/default/prometheus-node-exporter`), and
Prometheus reaches it because both use the host network.

**Grafana login fails with the vault password.** Rerun the deployment: the
monitoring role tests the vault password and resets it if it differs. To
reach Grafana from your machine:

```bash
ssh -L 3000:127.0.0.1:3000 <admin>@<server>     # then open http://localhost:3000
```

## Idempotency failures

`scripts/idempotency-check.sh` prints the tasks that reported changes on a
repeat run. Usual causes:

- a `command` task without `changed_when`;
- a template whose output varies between runs (timestamps, unordered loops over dicts);
- a package update published between the two runs (genuine change);
- a handler that runs every time because its notifying task is not idempotent.

Run the playbook twice with `--diff` to see exactly what differs.
