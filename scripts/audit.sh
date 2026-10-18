#!/usr/bin/env bash
# make audit: lista recursos na Hetzner com o rótulo deste projeto, direto
# pela API (somente leitura; não depende do estado local nem destrói nada).
# Serve para achar recursos órfãos: criados fora do OpenTofu (ex.: manualmente
# no console) ou que sobraram de uma destruição incompleta.
set -Eeuo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/tf.sh
source "$CDW_ROOT/scripts/lib/tf.sh"
# shellcheck source=scripts/lib/hcloud.sh
source "$CDW_ROOT/scripts/lib/hcloud.sh"

cdw_load_config

echo "Recursos na Hetzner com rótulo project=cloud-dev-workstation:"
labeled="$(hcloud_list_labeled)" ||
	die "falha ao consultar a API da Hetzner (token, rede ou resposta inesperada); não é seguro afirmar que não há recursos remanescentes."
if [[ -n "$labeled" ]]; then
	printf '  - %s\n' "${labeled//$'\n'/$'\n  - '}"
else
	echo "  (nenhum encontrado)"
fi
