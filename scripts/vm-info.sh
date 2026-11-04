#!/usr/bin/env bash
# Imprime, em linhas chave=valor, os dados da VM atual lidos do estado
# OpenTofu: id, IPv4, usuário e as chaves de host já conhecidas (known_hosts
# próprio da VM). Usado por scripts/cdw-push.ps1 (via wsl.exe) para achar a VM
# sem depender de um IP fixo. Não imprime segredos.
set -Eeuo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/tf.sh
source "$CDW_ROOT/scripts/lib/tf.sh"

cdw_load_config
cdw_setup_encryption
tf_init
tf_has_server || die "nenhuma VM no estado local; use make up"

server_id="$(tf_output server_id)"
printf 'server_id=%s\n' "$server_id"
printf 'ipv4=%s\n' "$(tf_output ipv4)"
printf 'username=%s\n' "$(tf_output username)"
known_hosts="$CDW_STATE_DIR/known_hosts.$server_id"
if [[ -f "$known_hosts" ]]; then
	while IFS= read -r line; do
		[[ -n "$line" && "$line" != \#* ]] && printf 'hostkey=%s\n' "$line"
	done <"$known_hosts"
fi
