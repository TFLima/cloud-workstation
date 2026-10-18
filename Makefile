# Cloud Dev Workstation — ponto de entrada das operações.
# Alvos de qualidade (lint/test/validate) nunca provisionam infraestrutura.

SHELL := bash
.SHELLFLAGS := -Eeuo pipefail -c
.DEFAULT_GOAL := help

TF ?= $(shell command -v tofu >/dev/null 2>&1 && echo tofu || echo terraform)
TF_DIR := infrastructure/terraform
SH_FILES := $(shell find scripts tests -name '*.sh' -type f | sort)

.PHONY: help init plan up status connect connect-print destroy-vm deploy backup down restore doctor \
	lint lint-sh lint-yaml lint-tf validate validate-tf validate-compose test check

help: ## Lista os alvos disponíveis
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-18s %s\n", $$1, $$2}'

## --- Operação ---
init: ## Valida dependências, variáveis e arquivos sem imprimir segredos
	@bash scripts/preflight.sh

plan: ## Mostra mudanças de infraestrutura e custo estimado (não cria nada)
	@bash scripts/plan.sh

up: ## Cria a VM, firewall e chave SSH (pede confirmação; recurso PAGO)
	@bash scripts/up.sh

status: ## Mostra IP, estado, bootstrap e saúde da VM
	@bash scripts/status.sh

connect: ## Abre uma sessão SSH na VM
	@bash scripts/connect.sh

connect-print: ## Mostra o comando SSH e o bloco para o VS Code Remote - SSH
	@bash scripts/connect.sh --print

destroy-vm: ## Destrói a VM SEM backup (pede confirmação digitada)
	@bash scripts/destroy-vm.sh

deploy: ## (Fase 3) Sobe stacks Docker por perfil
	@bash scripts/deploy.sh

backup: ## (Fase 4) Backup criptografado e verificado
	@bash scripts/backup.sh

down: ## (Fase 5) Backup, confirmação e destruição segura
	@bash scripts/destroy-safe.sh

restore: ## (Fase 4) Restaura dados em VM nova
	@bash scripts/restore.sh

doctor: ## Diagnóstico de SSH, Docker, disco, memória, rede e portas
	@bash scripts/doctor.sh

## --- Qualidade (sem provisionar nada) ---
lint: lint-sh lint-yaml lint-tf ## Roda todos os linters

lint-sh: ## shellcheck + shfmt
	shellcheck -x $(SH_FILES)
	shfmt -d $(SH_FILES)

lint-yaml: ## yamllint
	yamllint -s .

lint-tf: ## Formatação do OpenTofu/Terraform
	$(TF) -chdir=$(TF_DIR) fmt -check -recursive -diff

validate: validate-tf validate-compose ## Valida IaC e Compose

validate-tf: ## init sem backend + validate
	$(TF) -chdir=$(TF_DIR) init -backend=false -input=false >/dev/null
	$(TF) -chdir=$(TF_DIR) validate

validate-compose: ## docker compose config com todos os perfis
	POSTGRES_PASSWORD=validacao-local docker compose -f docker/compose.yaml --profile full config -q

test: ## Testes automatizados locais
	bash tests/run.sh

check: lint validate test ## Tudo o que o CI executa
