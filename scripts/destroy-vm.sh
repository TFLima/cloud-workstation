#!/usr/bin/env bash
# make destroy-vm: destrói VM, firewall e chave SSH SEM fazer backup.
# É a base que o make down (Fase 5) usará depois de um backup verificado.
set -Eeuo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/tf.sh
source "$CDW_ROOT/scripts/lib/tf.sh"

cdw_load_config
cdw_setup_encryption
tf_init
tf_has_server || die "nenhuma VM no estado local; nada a destruir"
cdw_export_tf_vars

name="$(tf_output server_name)"
server_id="$(tf_output server_id)"
echo "Recursos que serão DESTRUÍDOS (o IPv4 primário é excluído junto):"
tf_run state list | sed 's/^/  - /'
echo
echo "ATENÇÃO: não há backup automático nesta fase. Tudo o que estiver na VM será perdido."
expected="destruir $name"
if [[ "${CDW_CONFIRM:-}" != "$expected" ]]; then
	read -r -p "Digite '$expected' para continuar: " answer
	[[ "$answer" == "$expected" ]] || die "cancelado; nada foi destruído"
fi

tf_run destroy -input=false -auto-approve
rm -f "$CDW_STATE_DIR/known_hosts.$server_id"
log "destruído. Confira no console da Hetzner que não restaram recursos com rótulo project=cloud-dev-workstation."
