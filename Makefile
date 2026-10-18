# Cloud Dev Workstation — ponto de entrada das operações.
# Alvos de qualidade (lint/test/validate) nunca provisionam infraestrutura.

SHELL := bash
.SHELLFLAGS := -Eeuo pipefail -c
.DEFAULT_GOAL := help

TF ?= $(shell command -v tofu >/dev/null 2>&1 && echo tofu || echo terraform)
TF_DIR := infrastructure/terraform
SH_FILES := $(shell find scripts tests -name '*.sh' -type f | sort)

.PHONY: help init plan up status connect deploy backup down restore doctor \
	lint lint-sh lint-yaml lint-tf validate validate-tf validate-compose test check

help: ## Lista os alvos disponíveis
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-18s %s\n", $$1, $$2}'

## --- Operação ---
init: ## Valida dependências, variáveis e arquivos sem imprimir segredos
	@bash scripts/preflight.sh

plan: ## (Fase 2) Mostra mudanças de infraestrutura e custo estimado
	@echo "make plan será implementado na Fase 2." && exit 2

up: ## (Fase 2) Cria a VM, firewall e chave SSH
	@echo "make up será implementado na Fase 2." && exit 2

status: ## (Fase 2) Mostra IP, estado e saúde da VM
	@echo "make status será implementado na Fase 2." && exit 2

connect: ## (Fase 2) Mostra/abre o comando SSH seguro
	@echo "make connect será implementado na Fase 2." && exit 2

deploy: ## (Fase 3) Sobe stacks Docker por perfil
	@bash scripts/deploy.sh

backup: ## (Fase 4) Backup criptografado e verificado
	@bash scripts/backup.sh

down: ## (Fase 5) Backup, confirmação e destruição segura
	@bash scripts/destroy-safe.sh

restore: ## (Fase 4) Restaura dados em VM nova
	@bash scripts/restore.sh

doctor: ## (Fase 2) Diagnóstico de SSH, Docker, disco e memória
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
