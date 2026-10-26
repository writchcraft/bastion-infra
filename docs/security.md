# Security decisions

This page explains every security-relevant change Bastion makes, and why.
Bastion aims for understandable, defensible hardening, not a benchmark score.
Each setting below is something an administrator should be able to justify in
a review.

## Scope and threat model

The target is an internet-reachable Linux server run by a small team. The
threats addressed are:

- automated credential attacks against SSH;
- services exposed by accident (including through Docker);
- unpatched vulnerabilities in base packages;
- leaked secrets through the repository;
- administrators locking themselves out while applying hardening.

Out of scope: host intrusion detection, mandatory access control policy
authoring, full CIS/STIG compliance, and disk encryption. See "Deliberately not
done" below.

## Access model

| Control | Implementation |
|---|---|
| Named administrators | `admin_users` in the inventory; no shared accounts |
| Key-only login | Each admin needs at least one public key; placeholder keys are rejected |
| Authorised keys are declarative | `users_exclusive_keys: true` removes keys not listed in the inventory, so revoking access is a one-line change |
| Login allow-list | Only members of `sshusers` may log in (`AllowGroups`) |
| sudo | Admins join `sudo`. Passwordless sudo is granted per user in `/etc/sudoers.d/bastion-admins`, validated with `visudo -cf` before install |
| Default accounts | `users_disabled_accounts` locks accounts such as `ubuntu` (password locked, account expired, `nologin` shell). Nothing is deleted |
| Removed admins | `state: absent` deletes the account but keeps the home directory for review |

**Why passwordless sudo is the default:** key-only administrators have no
password, so sudo cannot ask for one. Requiring a password means managing
password hashes, which the role supports per user with `sudo_nopasswd: false`
and a `password_hash` from the vault. The trade-off is documented rather than
hidden.

## SSH

Bastion writes `/etc/ssh/sshd_config.d/00-bastion.conf`. sshd uses the first
value it reads for most keywords, and the `00-` prefix guarantees this file is
read before others such as cloud-init's `50-cloud-init.conf`, which on some
images sets `PasswordAuthentication yes`.

| Setting | Value | Reason |
|---|---|---|
| `PermitRootLogin` | `no` | Every action is attributable to a named admin; root is reached through sudo |
| `PasswordAuthentication` | `no` | Removes password guessing entirely |
| `KbdInteractiveAuthentication` | `no` | Closes the PAM password path as well |
| `AuthenticationMethods` | `publickey` | Makes the key-only policy explicit |
| `AllowGroups` | `sshusers` | Accounts outside the admin list cannot log in even if they have keys |
| `MaxAuthTries` | `3` | Limits guesses per connection; agents with many keys should use `IdentitiesOnly` |
| `LoginGraceTime` | `30` | Unauthenticated connections are dropped quickly |
| `ClientAliveInterval` / `CountMax` | `300` / `2` | Dead sessions are reaped after about 10 minutes |
| `X11Forwarding` | `no` | Not needed on a server |
| `AllowAgentForwarding` | `no` | Prevents a compromised server from using an admin's agent |
| `AllowTcpForwarding` | `local` | Allows `ssh -L` tunnels (used for Grafana) but not remote forwards that publish ports |
| `PermitTunnel` | `no` | No layer-2/3 tunnels |
| `LogLevel` | `VERBOSE` | Logs the fingerprint of the key used for each login, for audit |

**Ciphers, MACs and key exchange are not overridden.** OpenSSH 9.6 on Ubuntu
24.04 ships modern defaults that upstream maintains. Copy-pasted algorithm
lists age badly and are a common cause of lockouts with older clients.

### Lockout protection

1. **Bootstrap proves replacement access first.** Password logins are not disabled until a new key-based session as the admin has succeeded and `sudo` has returned root.
2. **Preflight guards.** The ssh role refuses to run if the current connection user would be excluded by `AllowGroups`, if root login is being disabled while connected as root, or if `ssh_port` differs from the port in use without `ssh_allow_port_change: true`.
3. **Validation before reload.** Each drop-in is validated standalone (`sshd -t -f`), then the full configuration is validated (`sshd -t`) before `systemctl reload ssh`.
4. **Dead man's switch.** A `systemd-run` timer restores the previous configuration after `ssh_rollback_timeout` seconds unless a fresh SSH login from the control machine succeeds first.
5. **Firewall ordering.** The firewall role runs before the ssh role and keeps the current connection port open during a port change.

## Firewall (UFW)

UFW is the standard Ubuntu front end to nftables. Policies are deny incoming,
allow outgoing, and deny routed (UFW's default; Docker installs its own
forwarding rules for container traffic).

| Rule | Source | Notes |
|---|---|---|
| SSH (`ssh_port`/tcp) | `firewall_ssh_allowed_sources` (default any) | `limit`: more than 6 connections in 30 s from one address are rejected |
| PostgreSQL (5432/tcp) | each `postgres_allowed_networks` CIDR | Added by the postgres role only when remote clients are configured |
| Grafana (3000/tcp) | each `monitoring_grafana_allowed_sources` entry | Added only when Grafana is bound beyond loopback |
| `firewall_rules` | as configured | Explicit extras, each tagged with a `bastion:` comment |

Every Bastion rule carries a `bastion: <service>` comment, so `ufw status`
shows why each port is open. UFW keeps rules until they are deleted, so
retiring a rule is explicit: list it once in `firewall_removed_rules`.

### Docker and UFW

Docker writes iptables rules for published ports that are evaluated before
UFW's. A container started with `-p 8080:80` is reachable from the internet
regardless of UFW. Bastion's own containers avoid this by using host
networking with explicit bind addresses. For any other containers:

- publish to loopback (`127.0.0.1:8080:80`) and put a reverse proxy in front; or
- add rules to the `DOCKER-USER` chain, which Docker evaluates first.

`verify.yml` fails if any unexpected TCP port is listening on a public
address, which catches this mistake.

## Security baseline

### Automatic security updates

`unattended-upgrades` installs packages from Ubuntu's `-security` pocket
daily. Bastion leaves the allowed origins at Ubuntu's default, so Docker
Engine and PostgreSQL (from their own repositories) are **not** upgraded
automatically: a database or container runtime restart should happen when an
operator runs Ansible. Automatic reboots are off by default
(`security_auto_reboot`). Pending reboots are reported by both the common role
and `verify.yml`.

### fail2ban

Bans an address for 1 hour after 5 failed SSH authentications within 10
minutes, reading the systemd journal directly. With password logins disabled
this mainly reduces log noise and wasted CPU from scanners. Admin networks
can be exempted with `fail2ban_ignore_networks`. The configuration is tested
with `fail2ban-client --test` before the service restarts.

### Kernel network parameters

Only settings that differ from Ubuntu's defaults are applied:

| Parameter | Value | Reason |
|---|---|---|
| `net.ipv4.conf.*.accept_redirects`, `net.ipv6.conf.*.accept_redirects` | 0 | A server should not let a neighbour rewrite its routes with ICMP redirects |
| `net.ipv4.conf.*.send_redirects` | 0 | The host is not a router |
| `net.ipv4.conf.*.log_martians` | 1 | Log packets with impossible source addresses (spoofing indicator) |

IP forwarding is left alone because Docker requires it. Ubuntu already enables
SYN cookies, reverse-path filtering, `kptr_restrict`, `dmesg_restrict` and the
`protected_*` filesystem settings; restating them would add noise without
adding protection.

### Services

`security_disabled_services` stops, disables and masks listed units. It is
empty by default because "unnecessary" depends on the server's role.

## Docker

- Installed from Docker's signed apt repository (deb822 source with `Signed-By`).
- The API is only on the local Unix socket. The role refuses a `hosts` key in `docker_daemon_options`, because a TCP socket without mutual TLS is a root shell for anyone who can reach it.
- `docker_users` is empty by default: docker group membership is root-equivalent.
- Container logs are rotated (`10m` × 3) so a noisy container cannot fill the disk.
- `live-restore` keeps containers running while the daemon restarts after a config change.

## PostgreSQL

- Listens on `localhost` unless `postgres_allowed_networks` is set.
- Local socket logins use `peer` authentication, so the OS user must match the role.
- All TCP logins require SCRAM-SHA-256 (`password_encryption = scram-sha-256`).
- Remote logins require TLS (`hostssl`) and are limited to each database's owner from the listed networks.
- `CONNECT` is revoked from `PUBLIC` on managed databases, so one application's role cannot connect to another application's database.
- Passwords come only from the vault, and tasks that handle them use `no_log`.

**Limitation:** the cluster uses Debian's self-signed "snakeoil" certificate.
Clients can require TLS (`sslmode=require`) but cannot verify the server
(`verify-full`) until a real certificate is installed.

## Grafana

- Bound to 127.0.0.1 by default and reached with `ssh -L 3000:127.0.0.1:3000 admin@server`.
- Sign-up, anonymous access, usage reporting and update checks are disabled.
- The admin password comes from the vault. Grafana only reads it when its database is created, so the role tests the vault password against the API on every run and resets it with `grafana cli` when it no longer matches. The password is passed on stdin, never on a command line.
- Dashboards are provisioned from files with UI edits disabled, so the repository is the source of truth.

## Secrets

See [secrets.md](secrets.md). In short: secrets live only in Ansible Vault
files that are git-ignored in this public repository, tasks that handle them
use `no_log`, and the Grafana env file is written with `diff: false` so
`--diff` runs do not print it.

## Deliberately not done

| Not done | Why |
|---|---|
| Full CIS benchmark | Hundreds of controls, many irrelevant or harmful for a given workload. Better added as a separate, opt-in role with each control justified |
| Custom cipher suites | See SSH above |
| Changing the SSH port by default | Obscurity, not security; supported via `ssh_port` with explicit confirmation |
| auditd rules | Valuable, but meaningful rules need a defined audit policy and log shipping |
| Disk encryption, partitioning | Destructive disk operations are out of scope for configuration management on an existing VM |
| Removing snapd and other packages by default | Depends on the workload; available through `security_disabled_services` |
