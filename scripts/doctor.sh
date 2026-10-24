#!/usr/bin/env bash
# make doctor: diagnostica a VM (SSH, Docker, disco, memória, rede, exposição de portas).
# Saída 0 = saudável; 1 = há problemas.
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
ip="$(tf_output ipv4)"
user="$(tf_output username)"

echo "Local:"
if cdw_ssh "$server_id" "$user@$ip" true 2>/dev/null; then
	echo "  [ok]    SSH em $user@$ip"
else
	echo "  [FALHA] SSH em $user@$ip não responde (confira o IP em TF_VAR_admin_cidr e rode make up)"
	exit 1
fi

echo "VM:"
cdw_ssh_script "$server_id" "$user@$ip" "$CDW_ROOT/scripts/lib/doctor-remote.sh"
