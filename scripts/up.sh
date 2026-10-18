#!/usr/bin/env bash
# make up: cria (ou ajusta) VM, chave SSH e firewall a partir de um plano novo,
# após confirmação explícita, e espera o bootstrap terminar.
set -Eeuo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/tf.sh
source "$CDW_ROOT/scripts/lib/tf.sh"

bash "$CDW_ROOT/scripts/plan.sh"

cdw_load_config
cdw_setup_encryption

echo
echo "ATENÇÃO: aplicar este plano cria recursos COBRADOS na Hetzner."
if [[ "${CDW_CONFIRM:-}" != "criar" ]]; then
	read -r -p "Digite 'criar' para continuar: " answer
	[[ "$answer" == "criar" ]] || die "cancelado; nada foi criado"
fi

existed="$(cat "$CDW_STATE_DIR/server-existed-before-plan" 2>/dev/null || echo 0)"

tf_run apply -input=false "$CDW_STATE_DIR/cdw.tfplan"
rm -f "$CDW_STATE_DIR/cdw.tfplan"

server_id="$(tf_output server_id)"
ip="$(tf_output ipv4)"
user="$(tf_output username)"

if [[ "$existed" == "1" ]]; then
	# VM já existia: user_data/ssh_keys ficam ignorados pelo lifecycle do
	# recurso (ver main.tf), então o bootstrap não roda de novo; esta aplicação
	# só pôde ter mudado firewall/chave SSH registrada. Não há versão nova de
	# bootstrap para esperar.
	log "VM já existia; esta aplicação só atualizou firewall/chave SSH (o bootstrap não é re-executado)"
	log "conferindo SSH em $ip"
	deadline=$((SECONDS + ${CDW_READY_TIMEOUT:-120}))
	until cdw_ssh "$server_id" "$user@$ip" true 2>/dev/null; do
		((SECONDS < deadline)) || die "SSH não respondeu; confira TF_VAR_admin_cidr e make status"
		sleep 5
	done
	log "VM pronta: $user@$ip. Próximo passo: make connect"
else
	want_version="$(tf_output bootstrap_version)"
	log "aguardando SSH e o bootstrap em $ip (pode levar alguns minutos)"
	deadline=$((SECONDS + ${CDW_READY_TIMEOUT:-900}))
	until cdw_ssh "$server_id" "$user@$ip" true 2>/dev/null; do
		((SECONDS < deadline)) || die "SSH não respondeu a tempo; rode make status"
		sleep 10
	done
	cdw_ssh "$server_id" "$user@$ip" 'cloud-init status --wait >/dev/null; cloud-init status --long | head -n 3'
	got="$(cdw_ssh "$server_id" "$user@$ip" 'cat /etc/cdw/bootstrap-version 2>/dev/null' || true)"
	[[ "$got" == "version=$want_version" ]] || die "bootstrap não concluiu (esperado version=$want_version, obtido '${got:-nada}'); veja /var/log/cdw-bootstrap.log na VM"
	log "VM pronta: $user@$ip (bootstrap $want_version). Próximo passo: make connect"
fi
