# Testing

Bastion is tested at four levels. Each one catches a different class of
mistake, and none of them is there for decoration.

| Level | Tool | Catches | Where |
|---|---|---|---|
| Static | `yamllint` | YAML syntax, indentation, truthy values, octal modes | `make lint`, CI |
| Static | `ansible-lint` (production profile) | Non-FQCN modules, missing `changed_when`, risky permissions, shell where a module exists | `make lint`, CI |
| Static | `ansible-playbook --syntax-check` | Broken playbook and role structure, unknown modules | `make syntax`, CI |
| Static | `shellcheck` | Quoting and error-handling bugs in scripts | CI |
| Integration | Real Ubuntu 24.04 VM | Everything modules actually do | CI `converge` job, or `make demo` on a dev VM |
| Behavioural | `verify.yml` | The server works: ports, services, auth, endpoints | after every deploy |
| Idempotency | `scripts/idempotency-check.sh` | Tasks that change something on every run | CI, `make idempotency` |

## The CI converge job

`.github/workflows/ci.yml` runs the full lifecycle on a GitHub-hosted
`ubuntu-24.04` runner, which is a real virtual machine with systemd, a
kernel firewall and root access:

1. generate an SSH key pair and a throw-away vault (`scripts/init-vault.sh ci`);
2. `bootstrap.yml` with a **local** connection as the runner account, creating the `bastion` admin;
3. `server.yml` over **real SSH to 127.0.0.1** as `bastion`, so the lockout guards, socket-activation switch, sshd reload and fresh-login confirmation all run for real;
4. `verify.yml`, whose report is uploaded as a build artifact;
5. `server.yml` again through `idempotency-check.sh`, which fails the build if any task reports `changed`.

No production infrastructure or credentials are involved.

### Why not Molecule with containers?

Most of what Bastion configures does not exist, or behaves differently,
inside a container: sshd under systemd, UFW and kernel netfilter, sysctl,
journald, timesyncd, Docker itself (Docker-in-Docker) and systemd timers. A
container-based Molecule scenario would need privileged mode and still
exercise less than half the roles honestly. A disposable VM tests the real
thing, and GitHub's runners provide one for free.

The trade-off is that the runner is not a *fresh* image: it ships with Docker,
PostgreSQL and many tools preinstalled. The roles are written to converge from
either state (they remove the legacy Docker source, reuse an existing cluster,
and keep chrony if present), which is itself a useful property. The truly fresh
path is exercised by the development VM workflow.

## Running the tests locally

```bash
make deps            # tooling and collections
make lint            # yamllint + ansible-lint
make syntax          # syntax-check all playbooks
```

Against a disposable VM (requires [Multipass](https://multipass.run)):

```bash
scripts/dev-vm.sh up
scripts/init-vault.sh development
export ANSIBLE_VAULT_PASSWORD_FILE=~/.config/bastion/development.vault-pass
make bootstrap
make demo            # deploy, verify, idempotency
scripts/dev-vm.sh down
```

## What the idempotency check proves

A second `server.yml` run against a configured server should report
`changed=0`. That holds because:

- modules are used for packages, files, users, services, firewall rules, repositories, sysctl and databases, and each one compares desired with actual state;
- every `command` task is read-only and marked `changed_when: false`, except where running it *is* the change (arming the SSH rollback timer);
- templates are deterministic (no timestamps; dict loops are sorted);
- handlers fire only when something they depend on changed;
- the Grafana password reset runs only when the stored password differs from the vault;
- image pulls use `policy: missing`, and `apt` uses `cache_valid_time`.

The one legitimate exception is a package update published between the two
runs.

## What is not tested automatically

- Multi-host inventories (the roles are host-local, but CI uses one host).
- `ssh_port` changes and SSH rollback after a failed login. The logic is reviewed and the rollback script is shellchecked, but CI does not deliberately break SSH.
- Restoring from a backup. The procedure is documented in [troubleshooting.md](troubleshooting.md#backups-and-restore).
- Reboot handling (`common_reboot_if_required`). CI cannot reboot its runner.
