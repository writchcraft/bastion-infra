# Configuration

## Supported platforms

| Component | Supported |
|---|---|
| Target OS | Ubuntu Server 24.04 LTS (amd64, arm64), checked by preflight |
| Control machine | Linux, macOS, or Windows via WSL2, with Python 3.10+ |
| ansible-core | 2.17 – 2.18 (`requirements-dev.txt`) |
| Collections | `requirements.yml`: ansible.posix, community.general, community.docker, community.postgresql |

Preflight stops on any other OS. `-e bastion_allow_unsupported_os=true`
overrides the check for experiments; it is not a support claim.

## Inventory structure

```text
ansible/inventories/
├── development/              single disposable VM (scripts/dev-vm.sh)
│   ├── hosts.yml
│   ├── host_vars/            git-ignored; dev-vm.sh writes the VM address here
│   └── group_vars/all/
│       ├── main.yml          environment configuration
│       ├── vault.yml         encrypted secrets (git-ignored)
│       └── vault.yml.example fake values, committed
├── production.example/       template: copy to inventories/production (git-ignored)
└── ci/                       used by GitHub Actions; the runner configures itself
```

`group_vars` sit inside each inventory rather than next to the playbooks, so
every environment carries its own configuration and the same playbook runs
unchanged against any of them. Hosts belong to the `bastion_servers` group,
which every playbook targets.

To create a real environment:

```bash
cp -r ansible/inventories/production.example ansible/inventories/production
$EDITOR ansible/inventories/production/hosts.yml
$EDITOR ansible/inventories/production/group_vars/all/main.yml
scripts/init-vault.sh production
make deploy ENV=production
```

## Precedence

```text
role defaults  <  inventory group_vars  <  inventory host_vars  <  role vars  <  -e extra vars
```

Role defaults are always safe to override. Role `vars/main.yml` (only in
`monitoring`) holds derived values and should not be overridden.

## Environment-level variables

These names are read by several roles, or describe the server in plain terms.

| Variable | Default | Used by | Description |
|---|---|---|---|
| `bootstrap_user` | — | bootstrap.yml | Account used for the first connection (`ubuntu` on cloud images) |
| `bootstrap_connection` | `ssh` | bootstrap.yml | Connection plugin for bootstrap (`local` in CI) |
| `bastion_admin_user` | — | all | Admin account every later run connects as; must be in `admin_users` |
| `ansible_user` | — | Ansible | Set to `{{ bastion_admin_user }}` in each inventory |
| `enable_docker` | `false` | server.yml | Apply the docker role |
| `enable_postgres` | `false` | server.yml | Apply the postgres role |
| `enable_monitoring` | `false` | server.yml | Apply the monitoring role (requires Docker) |
| `server_timezone` | `Etc/UTC` | common | IANA timezone |
| `server_locale` | `en_US.UTF-8` | common | System locale |
| `admin_users` | `[]` | users, ssh, verify | Administrator definitions (see users) |
| `ssh_port` | `22` | ssh, firewall, security | SSH port |
| `firewall_rules` | `[]` | firewall, verify | Extra inbound rules |
| `fail2ban_ignore_networks` | `[]` | security | Networks fail2ban never bans |
| `postgres_version` | `16` | postgres | PostgreSQL major version |
| `monitoring_domain` | `""` | monitoring | Public Grafana hostname when behind a proxy |

## Role variables

### common

| Variable | Default | Description |
|---|---|---|
| `common_manage_hostname` | `true` | Set the hostname and stop cloud-init resetting it |
| `common_hostname` | inventory name | Hostname |
| `common_packages` | see defaults | Baseline packages |
| `common_extra_packages` | `[]` | Additional packages for this environment |
| `common_upgrade_packages` | `true` | Apply pending upgrades (`apt-get upgrade --with-new-pkgs`) |
| `common_reboot_if_required` | `false` | Reboot when `/var/run/reboot-required` exists |
| `common_ntp_servers` | `[ntp.ubuntu.com]` | timesyncd servers (chrony, if installed, is left in charge) |
| `common_journald_system_max_use` | `1G` | Journal size cap |

### users

| Variable | Default | Description |
|---|---|---|
| `admin_users` | `[]` | List of administrators (fields below) |
| `users_ssh_group` | `sshusers` | Group allowed to log in over SSH |
| `users_default_shell` | `/bin/bash` | Shell when a user does not set one |
| `users_default_sudo_nopasswd` | `true` | Passwordless sudo unless a user says otherwise |
| `users_exclusive_keys` | `true` | Remove keys not listed in the inventory |
| `users_disabled_accounts` | `[]` | Existing accounts to lock (never deleted) |

`admin_users` fields:

| Field | Required | Default | Notes |
|---|---|---|---|
| `name` | yes | | lowercase, max 32 characters |
| `ssh_keys` | yes (unless absent) | | list of public keys |
| `comment` | no | | GECOS field |
| `shell` | no | `users_default_shell` | |
| `groups` | no | `[]` | extra groups that already exist |
| `sudo` | no | `true` | adds the user to `sudo` |
| `sudo_nopasswd` | no | `users_default_sudo_nopasswd` | |
| `password_hash` | when sudo needs a password | | SHA-512 crypt hash from the vault |
| `state` | no | `present` | `absent` removes the account, keeps the home directory |

### firewall

| Variable | Default | Description |
|---|---|---|
| `firewall_default_incoming` | `deny` | Incoming policy |
| `firewall_default_outgoing` | `allow` | Outgoing policy |
| `firewall_ssh_allowed_sources` | `[any]` | CIDRs allowed to reach SSH |
| `firewall_ssh_rate_limit` | `true` | Use UFW `limit` for SSH |
| `firewall_rules` | `[]` | `{port, proto, from, comment, rule}` |
| `firewall_removed_rules` | `[]` | Same format; rules to delete |
| `firewall_logging` | `low` | UFW log level |

### ssh

| Variable | Default | Description |
|---|---|---|
| `ssh_port` | `22` | Listening port |
| `ssh_listen_addresses` | `[]` | Empty = all addresses |
| `ssh_permit_root_login` | `"no"` | |
| `ssh_password_authentication` | `false` | |
| `ssh_allow_groups` | `[sshusers]` | Login allow-list; empty disables `AllowGroups` |
| `ssh_max_auth_tries` | `3` | |
| `ssh_allow_tcp_forwarding` | `local` | `local` permits `ssh -L` only |
| `ssh_log_level` | `VERBOSE` | |
| `ssh_disable_socket_activation` | `true` | Run sshd as `ssh.service` |
| `ssh_rollback_timeout` | `300` | Seconds before an unconfirmed change is rolled back |
| `ssh_allow_port_change` | `false` | Must be true to move a live server to a new port |

### security

| Variable | Default | Description |
|---|---|---|
| `security_unattended_upgrades` | `true` | Daily security updates |
| `security_auto_reboot` | `false` | Let unattended-upgrades reboot |
| `security_auto_reboot_time` | `"03:30"` | When it may reboot |
| `security_fail2ban` | `true` | SSH jail |
| `security_fail2ban_bantime` / `_findtime` / `_maxretry` | `1h` / `10m` / `5` | |
| `security_sysctl` | see defaults | Kernel parameters |
| `security_disabled_services` | `[]` | Units to stop, disable and mask |

### docker

| Variable | Default | Description |
|---|---|---|
| `docker_users` | `[]` | Users added to the docker group (root-equivalent) |
| `docker_log_max_size` / `docker_log_max_file` | `10m` / `3` | Container log rotation |
| `docker_live_restore` | `true` | Keep containers up across daemon restarts |
| `docker_daemon_options` | `{}` | Extra `daemon.json` keys (`hosts` is refused) |
| `docker_remove_conflicting_packages` | `true` | Remove Ubuntu's `docker.io` and related packages first |
| `docker_stacks_dir` / `docker_data_dir` | `/opt/bastion` / `/var/lib/bastion` | Stack config and persistent data roots |

### postgres

| Variable | Default | Description |
|---|---|---|
| `postgres_version` | `16` | Major version from PGDG |
| `postgres_users` | `[]` | `{name, password, role_attr_flags}`; passwords from the vault |
| `postgres_databases` | `[]` | `{name, owner, encoding, lc_collate, lc_ctype}` |
| `postgres_allowed_networks` | `[]` | Remote client CIDRs (TLS + SCRAM; opens UFW) |
| `postgres_settings` | `{}` | Extra `postgresql.conf` settings |
| `postgres_log_connections` | `false` | Log connections and disconnections |
| `postgres_backup_enabled` | `true` | Nightly `pg_dump` timer |
| `postgres_backup_dir` | `/var/backups/postgresql` | Backup location |
| `postgres_backup_schedule` | `*-*-* 02:30:00` | systemd `OnCalendar` |
| `postgres_backup_retention_days` | `7` | Older dumps are deleted |

### monitoring

| Variable | Default | Description |
|---|---|---|
| `monitoring_prometheus_image` | `prom/prometheus:v3.1.0` | Pinned image |
| `monitoring_grafana_image` | `grafana/grafana:11.4.0` | Pinned image |
| `monitoring_scrape_interval` | `15s` | |
| `monitoring_prometheus_retention` | `15d` | TSDB retention |
| `monitoring_grafana_listen_address` | `127.0.0.1` | `0.0.0.0` to expose (requires allowed sources) |
| `monitoring_grafana_allowed_sources` | `[]` | CIDRs opened in UFW for Grafana |
| `monitoring_grafana_admin_user` | `admin` | |
| `monitoring_grafana_admin_password` | `""` | From the vault; at least 12 characters |

### verify.yml

| Variable | Default | Description |
|---|---|---|
| `verify_extra_public_ports` | `[]` | TCP ports allowed to listen publicly in addition to SSH and configured services |

verify.yml reads the same inventory variables as the roles and applies the
same defaults. If you override a role default in the inventory, verification
checks the overridden value.
