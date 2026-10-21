# Thin wrapper around ansible-playbook. Every target prints the command it
# runs, so nothing here is hidden from the operator.
#
#   make deploy                    # development inventory
#   make deploy ENV=production     # any inventory under ansible/inventories
#   make deploy ARGS="--tags ssh --diff"

ENV ?= development
ARGS ?=
INVENTORY := inventories/$(ENV)

# Prompt for the vault password unless a password file is configured.
VAULT_ARGS := $(if $(ANSIBLE_VAULT_PASSWORD_FILE),,--ask-vault-pass)
PLAYBOOK := cd ansible && ansible-playbook -i $(INVENTORY) $(VAULT_ARGS)

.DEFAULT_GOAL := help
.PHONY: help deps lint syntax vault bootstrap deploy verify idempotency demo

help: ## Show available targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

deps: ## Install control-node tooling and Ansible collections
	pip install -r requirements-dev.txt
	ansible-galaxy collection install -r requirements.yml

lint: ## Run yamllint and ansible-lint
	yamllint .
	ANSIBLE_CONFIG=ansible/ansible.cfg ansible-lint

syntax: ## Syntax-check every playbook
	cd ansible && for playbook in playbooks/*.yml; do \
		ansible-playbook -i inventories/production.example --syntax-check "$$playbook" || exit 1; \
	done

vault: ## Create an encrypted vault.yml with random secrets for ENV
	scripts/init-vault.sh $(ENV)

bootstrap: ## First run on a fresh server: create the admin user
	$(PLAYBOOK) playbooks/bootstrap.yml $(ARGS)

deploy: ## Configure the server(s)
	$(PLAYBOOK) playbooks/server.yml $(ARGS)

verify: ## Check the deployment and write reports/verify-<host>.md
	$(PLAYBOOK) playbooks/verify.yml $(ARGS)

idempotency: ## Rerun the deployment and fail if anything changes
	cd ansible && ../scripts/idempotency-check.sh -i $(INVENTORY) $(VAULT_ARGS) playbooks/server.yml $(ARGS)

demo: deploy verify idempotency ## Deploy, verify, then prove idempotency
