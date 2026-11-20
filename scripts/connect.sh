#!/usr/bin/env bash
# make connect: abre uma sessão SSH na VM. Com --print, só mostra o comando e o
# bloco de configuração para o VS Code Remote - SSH.
set -Eeuo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/tf.sh
source "$CDW_ROOT/scripts/lib/tf.sh"
# shellcheck source=scripts/lib/sshkey.sh
source "$CDW_ROOT/scripts/lib/sshkey.sh"

cdw_load_config
cdw_setup_encryption
tf_init
tf_has_server || die "nenhuma VM no estado local; use make up"

server_id="$(tf_output server_id)"
ip="$(tf_output ipv4)"
user="$(tf_output username)"
known_hosts="$CDW_STATE_DIR/known_hosts.$server_id"

# IdentityFile do bloco para o Windows. Um caminho do WSL (/home/...) não
# existe para o OpenSSH do Windows; por isso o bloco usa o caminho do Windows
# da chave configurada, e avisa quando a chave do Windows é outra.
windows_identity() {
	local win_dir win_path md5
	win_path="$(cdw_windows_path "$CDW_SSH_PRIVATE_KEY_FILE")"
	if [[ -n "$win_path" ]]; then
		printf '%s\n' "$win_path"
		return 0
	fi
	win_dir="$(cdw_windows_ssh_dir)"
	md5="$(cdw_key_fp "$CDW_SSH_PUBLIC_KEY_FILE" md5 2>/dev/null || true)"
	if [[ -n "$win_dir" ]]; then
		win_path="$(cdw_windows_path "$win_dir/id_ed25519")"
		printf '%s\n' "${win_path:-~/.ssh/id_ed25519}"
		if [[ "$(cdw_key_fp "$win_dir/id_ed25519.pub" md5 2>/dev/null || true)" != "$md5" ]]; then
			printf '    # ATENÇÃO: esta chave do Windows não é a do .env; rode "make authorize-key" (docs/ssh-key.md)\n'
		fi
	else
		# shellcheck disable=SC2088 # o "~" é literal: quem expande é o OpenSSH do Windows
		printf '~/.ssh/id_ed25519\n'
		printf '    # No Windows, ~ é C:\\Users\\<você>. A chave precisa ser a do .env (MD5 %s); confira com "make key-check"\n' "$md5"
	fi
}

if [[ "${1:-}" == "--print" ]]; then
	identity="$(windows_identity)"
	cat <<TXT
Comando SSH (no WSL):
  ssh -i $CDW_SSH_PRIVATE_KEY_FILE -o IdentitiesOnly=yes -o UserKnownHostsFile=$known_hosts -o StrictHostKeyChecking=accept-new $user@$ip

Bloco para ~/.ssh/config (no Windows: C:\\Users\\<você>\\.ssh\\config) usado pelo VS Code Remote - SSH:
  Host cdw
    HostName $ip
    User $user
    IdentityFile $identity
    IdentitiesOnly yes
    ServerAliveInterval 30
    # Túneis para serviços internos (opcional):
    # LocalForward 5432 127.0.0.1:5432
    # LocalForward 6379 127.0.0.1:6379

No VS Code: F1 > "Remote-SSH: Connect to Host..." > cdw.
O IP muda a cada make up; no PowerShell, "cdw-push -ConfigOnly" atualiza HostName sozinho.
TXT
	exit 0
fi

mapfile -t opts < <(cdw_ssh_opts "$server_id")
exec ssh "${opts[@]}" "$user@$ip"
