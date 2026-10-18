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
tf_init

location="${TF_VAR_location:?}"
existed=0
if tf_has_server; then
	existed=1
fi

if ((existed)); then
	# A VM já existe: o tipo não é re-escolhido a cada make plan (isso evitaria
	# redimensionar a VM só porque o tipo principal voltou a ter estoque).
	chosen="$(tf_output server_type)"
	log "VM existente com tipo $chosen; mantendo esse tipo (defina CDW_FORCE_RESELECT=1 para escolher de novo)"
	if [[ "${CDW_FORCE_RESELECT:-0}" == "1" ]]; then
		if ! selection="$(hcloud_select_type "$location" "${TF_VAR_server_type:?}" "${CDW_SERVER_TYPE_FALLBACKS:-}")"; then
			die "nenhum tipo de servidor disponível em $location; tente outra localização"
		fi
		read -r chosen hourly monthly <<<"$selection"
	else
		result="$(hcloud_check_type "$chosen" "$location")"
		if [[ "$result" == ok* ]]; then
			read -r _ hourly monthly <<<"$result"
		else
			hourly="?"
			monthly="?"
			warn "não foi possível obter o preço atual de $chosen (${result#indisponivel })"
		fi
	fi

	# Trava de segurança: a VM só tem a chave com que foi criada (o bootstrap
	# não é re-executado em cima de uma VM existente). Trocar a chave local sem
	# avisar bloquearia o próprio acesso.
	key_fp="$(cdw_local_key_fingerprint)"
	fp_file="$CDW_STATE_DIR/ssh-key-fingerprint"
	if [[ -f "$fp_file" ]]; then
		recorded_fp="$(cat "$fp_file")"
		if [[ "$recorded_fp" != "$key_fp" && "${CDW_ALLOW_KEY_ROTATION:-0}" != "1" ]]; then
			die "a chave pública local mudou desde que esta VM foi criada; aplicar agora poderia bloquear seu próprio acesso.
Para trocar a chave sem perder acesso: conecte com a chave antiga, adicione a nova em
~/.ssh/authorized_keys na VM manualmente, e então rode de novo com CDW_ALLOW_KEY_ROTATION=1.
Alternativa: make destroy-vm && make up recria a VM já com a chave atual."
		fi
	else
		printf '%s\n' "$key_fp" >"$fp_file"
	fi
else
	log "conferindo disponibilidade em $location"
	if ! selection="$(hcloud_select_type "$location" "${TF_VAR_server_type:?}" "${CDW_SERVER_TYPE_FALLBACKS:-}")"; then
		die "nenhum tipo de servidor disponível em $location; tente outra localização"
	fi
	read -r chosen hourly monthly <<<"$selection"
	printf '%s\n' "$(cdw_local_key_fingerprint)" >"$CDW_STATE_DIR/ssh-key-fingerprint"
fi

export TF_VAR_server_type="$chosen"
ipv4="$(hcloud_ipv4_monthly "$location")"

tf_run plan -input=false -out="$CDW_STATE_DIR/cdw.tfplan"

awk -v t="$chosen" -v l="$location" -v h="$hourly" -v m="$monthly" -v ip="${ipv4:-?}" 'BEGIN {
	printf "\nESTIMATIVA de custo (preços líquidos da API Hetzner, sem IVA):\n"
	if (h == "?" || m == "?") {
		printf "  servidor %s em %s: preço indisponível agora\n", t, l
	} else {
		printf "  servidor %s em %s: EUR %.4f/h (teto EUR %.2f/mês)\n", t, l, h, m
		printf "  sessão de 8 h: ~EUR %.2f   | IPv4 primário: EUR %s/mês enquanto existir\n", h * 8, ip
	}
	printf "  após make down (sem snapshots/volumes): EUR 0 na Hetzner\n"
}'
printf '%s\n' "$chosen" >"$CDW_STATE_DIR/selected-server-type"
printf '%s\n' "$existed" >"$CDW_STATE_DIR/server-existed-before-plan"
log "plano salvo; nada foi criado. Para aplicar: make up"
