#!/usr/bin/env bash
# make plan: escolhe o tipo de servidor disponível, mostra o custo estimado e
# gera um plano OpenTofu salvo (criptografado). Não cria nada.
set -Eeuo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/tf.sh
source "$CDW_ROOT/scripts/lib/tf.sh"
# shellcheck source=scripts/lib/hcloud.sh
source "$CDW_ROOT/scripts/lib/hcloud.sh"

cdw_load_config
bash "$CDW_ROOT/scripts/preflight.sh" >/dev/null || die "preflight falhou; rode make init para ver os detalhes"
cdw_export_tf_vars
cdw_setup_encryption

location="${TF_VAR_location:?}"
log "conferindo disponibilidade em $location"
if ! selection="$(hcloud_select_type "$location" "${TF_VAR_server_type:?}" "${CDW_SERVER_TYPE_FALLBACKS:-}")"; then
	die "nenhum tipo de servidor disponível em $location; tente outra localização"
fi
read -r chosen hourly monthly <<<"$selection"
export TF_VAR_server_type="$chosen"
ipv4="$(hcloud_ipv4_monthly "$location")"

tf_init
tf_run plan -input=false -out="$CDW_STATE_DIR/cdw.tfplan"

awk -v t="$chosen" -v l="$location" -v h="$hourly" -v m="$monthly" -v ip="${ipv4:-?}" 'BEGIN {
	printf "\nESTIMATIVA de custo (preços líquidos da API Hetzner, sem IVA):\n"
	printf "  servidor %s em %s: EUR %.4f/h (teto EUR %.2f/mês)\n", t, l, h, m
	printf "  sessão de 8 h: ~EUR %.2f   | IPv4 primário: EUR %s/mês enquanto existir\n", h * 8, ip
	printf "  após make down (sem snapshots/volumes): EUR 0 na Hetzner\n"
}'
printf '%s\n' "$chosen" >"$CDW_STATE_DIR/selected-server-type"
log "plano salvo; nada foi criado. Para aplicar: make up"
