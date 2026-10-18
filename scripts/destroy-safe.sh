#!/usr/bin/env bash
# make down: backup verificado, auditoria de recursos/custo residual,
# confirmação e destruição (VM, firewall, chave SSH, IPv4 primário).
# Falha de forma segura: se o backup falhar, nada é destruído.
set -Eeuo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/tf.sh
source "$CDW_ROOT/scripts/lib/tf.sh"
# shellcheck source=scripts/lib/hcloud.sh
source "$CDW_ROOT/scripts/lib/hcloud.sh"

cdw_load_config
cdw_setup_encryption
tf_init
tf_has_server || die "nenhuma VM no estado local; nada a destruir"

if [[ "${CDW_SKIP_BACKUP:-0}" == "1" ]]; then
	warn "CDW_SKIP_BACKUP=1: destruindo SEM fazer um backup novo agora. Dados criados ou alterados desde o último make backup serão perdidos."
else
	log "fazendo backup antes de destruir (make backup; ver docs/adr/0003-persistencia-e-backup.md)"
	bash "$CDW_ROOT/scripts/backup.sh" ||
		die "o backup falhou; a destruição foi interrompida e NADA foi destruído. Corrija o problema e rode make down de novo (ou, por sua conta e risco, CDW_SKIP_BACKUP=1)."
	log "backup concluído e verificado (restic check); seguindo para a destruição"
fi

# Destruir não depende de SSH nem do IP atual do operador: usa valores
# fictícios quando a chave local ou a rede não estão disponíveis, para que
# perder a chave nunca trave o caminho de parar a cobrança (mesmo padrão do
# make destroy-vm).
cdw_export_tf_vars_for_destroy

name="$(tf_output server_name)"
server_id="$(tf_output server_id)"
server_type="$(tf_output server_type)"
location="$(tf_output location)"

echo
echo "Recursos que serão DESTRUÍDOS (o IPv4 primário é excluído junto com o servidor):"
tf_run state list | sed 's/^/  - /'
echo "Nenhum volume ou snapshot é usado neste desenho (ADR-0003: backups = false);"
echo "nada além do listado acima fica retido ou cobrado por este projeto na Hetzner."

price_result="$(hcloud_check_type "$server_type" "$location" 2>/dev/null || true)"
if [[ "$price_result" == ok* ]]; then
	read -r _ hourly monthly <<<"$price_result"
	echo
	echo "Custo que deixa de ser cobrado: EUR $hourly/h (teto EUR $monthly/mês) + IPv4 primário."
fi

echo
echo "Auditoria de recursos com rótulo project=cloud-dev-workstation na Hetzner:"
labeled="$(hcloud_list_labeled 2>/dev/null || true)"
if [[ -n "$labeled" ]]; then
	printf '  - %s\n' "${labeled//$'\n'/$'\n  - '}"
else
	echo "  (nenhum encontrado pela API; a lista acima do estado local é a referência)"
fi

expected="destruir $name"
if [[ "${CDW_CONFIRM:-}" != "$expected" ]]; then
	read -r -p "Digite '$expected' para continuar: " answer
	[[ "$answer" == "$expected" ]] || die "cancelado; nada foi destruído (o backup acima, se foi feito, continua válido)"
fi

tf_run destroy -input=false -auto-approve
rm -f "$CDW_STATE_DIR/known_hosts.$server_id"
log "destruído."

log "conferindo recursos remanescentes com rótulo project=cloud-dev-workstation..."
remaining="$(hcloud_list_labeled 2>/dev/null || true)"
if [[ -z "$remaining" ]]; then
	log "nenhum recurso remanescente; custo residual na Hetzner: EUR 0."
else
	warn "ainda há recursos com esse rótulo na Hetzner (confira no console, pode ser atraso da API):"
	printf '  - %s\n' "${remaining//$'\n'/$'\n  - '}"
fi
