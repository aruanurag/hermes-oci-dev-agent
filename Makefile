SHELL := /bin/bash

TF_DIR ?= terraform
OCI_PROFILE ?= DEFAULT
SSH_PRIVATE_KEY ?= $(HOME)/.ssh/id_rsa
LOCAL_SSH_PORT ?= 2222
LOCAL_DASHBOARD_PORT ?= 9119
BASTION_SESSION_TTL ?= 10800

.DEFAULT_GOAL := help
.PHONY: help check-tfvars check-ssh-key plan provision dashboard up destroy

help:
	@echo "Targets:"
	@echo "  make plan       Preview Terraform changes."
	@echo "  make provision  Create or update the private OCI Hermes stack."
	@echo "  make dashboard  Open a temporary Bastion tunnel at http://localhost:9119."
	@echo "  make up         Provision, then open the Dashboard tunnel."
	@echo "  make destroy    Destroy the Terraform-managed OCI stack."
	@echo
	@echo "Optional overrides: OCI_PROFILE=HERMES SSH_PRIVATE_KEY=\$$HOME/.ssh/id_ed25519 LOCAL_DASHBOARD_PORT=9919"

check-tfvars:
	@test -f "$(TF_DIR)/terraform.tfvars" || { \
		echo "Missing $(TF_DIR)/terraform.tfvars. Copy terraform.tfvars.example and fill its required values."; \
		exit 1; \
	}

check-ssh-key:
	@test -f "$(SSH_PRIVATE_KEY)" || { echo "Private key not found: $(SSH_PRIVATE_KEY)"; exit 1; }
	@test -f "$(SSH_PRIVATE_KEY).pub" || { echo "Public key not found: $(SSH_PRIVATE_KEY).pub"; exit 1; }

plan: check-tfvars
	terraform -chdir="$(TF_DIR)" init -input=false
	terraform -chdir="$(TF_DIR)" plan -var="oci_config_file_profile=$(OCI_PROFILE)"

provision: check-tfvars
	terraform -chdir="$(TF_DIR)" init -input=false
	terraform -chdir="$(TF_DIR)" apply -var="oci_config_file_profile=$(OCI_PROFILE)"

dashboard: check-tfvars check-ssh-key
	./scripts/open-dashboard-tunnel.sh \
		--terraform-dir "$(TF_DIR)" \
		--oci-profile "$(OCI_PROFILE)" \
		--ssh-private-key "$(SSH_PRIVATE_KEY)" \
		--local-ssh-port "$(LOCAL_SSH_PORT)" \
		--local-dashboard-port "$(LOCAL_DASHBOARD_PORT)" \
		--session-ttl "$(BASTION_SESSION_TTL)"

up: provision
	@$(MAKE) dashboard \
		TF_DIR="$(TF_DIR)" \
		OCI_PROFILE="$(OCI_PROFILE)" \
		SSH_PRIVATE_KEY="$(SSH_PRIVATE_KEY)" \
		LOCAL_SSH_PORT="$(LOCAL_SSH_PORT)" \
		LOCAL_DASHBOARD_PORT="$(LOCAL_DASHBOARD_PORT)" \
		BASTION_SESSION_TTL="$(BASTION_SESSION_TTL)"

destroy: check-tfvars
	terraform -chdir="$(TF_DIR)" destroy -var="oci_config_file_profile=$(OCI_PROFILE)"
