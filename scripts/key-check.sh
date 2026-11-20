#!/usr/bin/env bash
# make key-check: confere se a chave SSH é a mesma em todos os lugares --
# no .env (a que vai para cada VM nova), no Windows (a que o VS Code usa), na
# Hetzner e na VM atual. Só lê arquivos .pub; nunca imprime a chave privada.
# Saída 0 = a VM atual aceita a chave configurada; 1 = há algo a corrigir.
set -Eeuo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/tf.sh
source "$CDW_ROOT/scripts/lib/tf.sh"
# shellcheck source=scripts/lib/hcloud.sh
source "$CDW_ROOT/scripts/lib/hcloud.sh"
# shellcheck source=scripts/lib/sshkey.sh
source "$CDW_ROOT/scripts/lib/sshkey.sh"

problems=0
fail() {
	printf '  [FALHA] %s\n' "$*"
	problems=$((problems + 1))
}
ok() { printf '  [ok]    %s\n' "$*"; }
note() { printf '  [aviso] %s\n' "$*"; }

cdw_load_config
pub="$CDW_SSH_PUBLIC_KEY_FILE"
[[ -f "$pub" ]] || die "chave pública não encontrada: $pub (CDW_SSH_PUBLIC_KEY_FILE)"
md5="$(cdw_key_fp "$pub" md5)" || die "arquivo de chave pública inválido: $pub"
sha="$(cdw_key_fp "$pub" sha256)"

echo "Chave configurada (CDW_SSH_PUBLIC_KEY_FILE, vai para toda VM nova):"
echo "  arquivo : $pub"
echo "  MD5     : $md5   (formato do console da Hetzner)"
echo "  SHA256  : $sha"
if [[ -f "$CDW_SSH_PRIVATE_KEY_FILE" ]]; then
	mode="$(file_mode "$CDW_SSH_PRIVATE_KEY_FILE")"
	if [[ "${mode: -2}" == "00" ]]; then
		ok "chave privada presente com permissão restrita"
	else
		fail "chave privada com permissão $mode; o ssh a ignora. Use: chmod 600 $CDW_SSH_PRIVATE_KEY_FILE"
	fi
else
	fail "chave privada não encontrada em $CDW_SSH_PRIVATE_KEY_FILE (CDW_SSH_PRIVATE_KEY_FILE)"
fi

echo "Windows (VS Code Remote - SSH):"
win_dir="$(cdw_windows_ssh_dir)"
win_same=0
if [[ -z "$win_dir" ]]; then
	note "pasta .ssh do Windows não encontrada (fora do WSL, ou defina CDW_WINDOWS_SSH_DIR=/mnt/c/Users/<você>/.ssh)"
else
	win_pub="$win_dir/id_ed25519.pub"
	win_md5="$(cdw_key_fp "$win_pub" md5 || true)"
	if [[ "$win_md5" == "$md5" ]]; then
		win_same=1
		ok "o Windows usa a mesma chave ($win_pub)"
	else
		note "o Windows usa OUTRA chave ($win_pub, MD5 $win_md5)."
		note "  Para ter uma chave só, veja \"Chave SSH definitiva\" em docs/ssh-key.md."
	fi
fi

echo "Hetzner (chave ${TF_VAR_name}-operator, usada na criação da VM):"
if [[ -z "${HCLOUD_TOKEN:-}" ]]; then
	note "HCLOUD_TOKEN não definido; não consultei a Hetzner"
elif hz_md5="$(cdw_hetzner_key_fp)"; then
	if [[ -z "$hz_md5" ]]; then
		note "nenhuma chave ${TF_VAR_name}-operator na Hetzner (normal sem VM)"
	elif [[ "$hz_md5" == "$md5" ]]; then
		ok "a chave registrada é a configurada"
	else
		note "a chave registrada é outra (MD5 $hz_md5). A VM atual foi criada com ela;"
		note "  Se a VM aceitar a chave configurada (abaixo), está tudo bem; o registro na Hetzner"
		note "  é trocado no próximo make up (VM existente: CDW_ALLOW_KEY_ROTATION=1; não recria a VM)."
	fi
else
	note "não consegui consultar a API da Hetzner"
fi

echo "VM atual:"
cdw_setup_encryption
tf_init
if ! tf_has_server; then
	note "nenhuma VM no estado local; a próxima (make up) já nasce com a chave configurada"
else
	server_id="$(tf_output server_id)"
	target="$(tf_output username)@$(tf_output ipv4)"
	mapfile -t opts < <(cdw_ssh_opts "$server_id")
	if ssh "${opts[@]}" -o BatchMode=yes "$target" true 2>/dev/null; then
		ok "a VM aceita a chave configurada ($target)"
		if [[ -n "$win_dir" && "$win_same" == 0 ]]; then
			win_line="$(cdw_pubkey_line "$win_pub" || true)"
			# shellcheck disable=SC2029 # a linha da chave pública é passada como texto, entre aspas
			if [[ -n "$win_line" ]] && ssh "${opts[@]}" -o BatchMode=yes "$target" "grep -qF -- '$win_line' ~/.ssh/authorized_keys" 2>/dev/null; then
				ok "a chave do Windows também está autorizada na VM"
			else
				fail "a chave do Windows NÃO está autorizada na VM; rode: make authorize-key"
			fi
		fi
	else
		fail "a VM recusou a chave configurada (ou não respondeu). Veja docs/ssh-key.md"
	fi
fi

echo
if ((problems > 0)); then
	echo "key-check: $problems problema(s)."
	exit 1
fi
echo "key-check: tudo certo."
