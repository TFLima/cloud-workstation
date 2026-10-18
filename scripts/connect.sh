#!/usr/bin/env bash
# make connect: abre uma sessão SSH na VM. Com --print, só mostra o comando e o
# bloco de configuração para o VS Code Remote - SSH.
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
known_hosts="$CDW_STATE_DIR/known_hosts.$server_id"

if [[ "${1:-}" == "--print" ]]; then
	cat <<TXT
Comando SSH:
  ssh -o UserKnownHostsFile=$known_hosts -o StrictHostKeyChecking=accept-new $user@$ip

Bloco para ~/.ssh/config (no Windows: C:\\Users\\<você>\\.ssh\\config) usado pelo VS Code Remote - SSH:
  Host cdw
    HostName $ip
    User $user
    IdentityFile ${CDW_SSH_PRIVATE_KEY_FILE/#$HOME/~}
    IdentitiesOnly yes
    ServerAliveInterval 30
    # Túneis para serviços internos (opcional):
    # LocalForward 5432 127.0.0.1:5432
    # LocalForward 6379 127.0.0.1:6379

No VS Code: F1 > "Remote-SSH: Connect to Host..." > cdw.
O IP muda a cada make up; atualize HostName após recriar a VM.
TXT
	exit 0
fi

mapfile -t opts < <(cdw_ssh_opts "$server_id")
exec ssh "${opts[@]}" "$user@$ip"
