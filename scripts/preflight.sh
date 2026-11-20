#!/usr/bin/env bash
# make init: valida dependências locais, variáveis e arquivos sem imprimir segredos.
# Saída 0 = pronto; 1 = há problemas a corrigir.
set -Eeuo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/hcloud.sh
source "$CDW_ROOT/scripts/lib/hcloud.sh"
# shellcheck source=scripts/lib/sshkey.sh
source "$CDW_ROOT/scripts/lib/sshkey.sh"

ENV_FILE="${CDW_ENV_FILE:-$CDW_ROOT/.env}"
problems=0

fail() {
	printf '  [FALHA] %s\n' "$*"
	problems=$((problems + 1))
}
ok() { printf '  [ok]    %s\n' "$*"; }
skip() { printf '  [aviso] %s\n' "$*"; }

load_env_file "$ENV_FILE"

echo "Dependências locais:"
for cmd in bash ssh ssh-keygen curl jq make git; do
	if has_cmd "$cmd"; then ok "$cmd"; else fail "$cmd não encontrado"; fi
done
if tf="$(tf_bin)"; then
	ok "IaC: $tf"
	[[ "$tf" == "tofu" ]] || skip "OpenTofu não encontrado; usando $tf (sem criptografia nativa de estado)"
else
	fail "nem tofu nem terraform encontrados"
fi
if has_cmd restic; then ok "restic"; else skip "restic ausente (só é necessário para recuperar o estado em outro computador)"; fi

echo "Configuração:"
if [[ -f "$ENV_FILE" ]]; then ok ".env presente com permissão restrita"; else skip ".env não encontrado; usando apenas o ambiente"; fi

for var in HCLOUD_TOKEN TF_VAR_location TF_VAR_server_type; do
	if env_is_set "$var"; then ok "$var definido"; else fail "$var não definido"; fi
done

token="${HCLOUD_TOKEN:-}"
if [[ -n "$token" && ! "$token" =~ ^[A-Za-z0-9]{64}$ ]]; then
	fail "HCLOUD_TOKEN não tem o formato esperado (64 caracteres alfanuméricos)"
fi

admin_cidr="${TF_VAR_admin_cidr:-}"
if [[ -n "$admin_cidr" ]]; then
	if [[ "$admin_cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/(3[0-2]|[12]?[0-9])$ ]]; then
		if [[ "$admin_cidr" == "0.0.0.0/0" ]]; then
			fail "TF_VAR_admin_cidr não pode ser 0.0.0.0/0"
		else
			ok "TF_VAR_admin_cidr válido"
		fi
	else
		fail "TF_VAR_admin_cidr inválido (use x.x.x.x/32)"
	fi
else
	skip "TF_VAR_admin_cidr vazio; o IP atual será detectado no make up"
fi

key_file="$(expand_path "${CDW_SSH_PUBLIC_KEY_FILE:-~/.ssh/id_ed25519.pub}")"
if [[ -f "$key_file" ]]; then
	if ssh-keygen -l -f "$key_file" >/dev/null 2>&1; then
		ok "chave pública SSH válida"
	else
		fail "arquivo de chave pública SSH inválido"
	fi
	if grep -q 'PRIVATE KEY' "$key_file"; then
		fail "o arquivo indicado contém uma chave PRIVADA; aponte para o .pub"
	fi
	# A mesma chave em todo lugar (docs/ssh-key.md): avisos, não falhas, para
	# não bloquear quem usa de propósito chaves diferentes.
	key_md5="$(cdw_key_fp "$key_file" md5 || true)"
	win_dir="$(cdw_windows_ssh_dir)"
	if [[ -n "$key_md5" && -n "$win_dir" ]]; then
		if [[ "$(cdw_key_fp "$win_dir/id_ed25519.pub" md5 || true)" == "$key_md5" ]]; then
			ok "o Windows (VS Code) usa a mesma chave SSH"
		else
			skip "o Windows ($win_dir) usa OUTRA chave SSH; o VS Code não vai entrar nas VMs novas (ver docs/ssh-key.md)"
		fi
	fi
	if [[ -n "$key_md5" && "$token" =~ ^[A-Za-z0-9]{64}$ ]]; then
		if hz_md5="$(TF_VAR_name="${TF_VAR_name:-cdw}" cdw_hetzner_key_fp)"; then
			if [[ -n "$hz_md5" && "$hz_md5" != "$key_md5" ]]; then
				skip "a chave ${TF_VAR_name:-cdw}-operator na Hetzner (MD5 $hz_md5) não é a do .env (MD5 $key_md5); a VM atual foi criada com a outra. Rode make key-check"
			elif [[ -n "$hz_md5" ]]; then
				ok "a chave registrada na Hetzner é a do .env"
			fi
		else
			skip "não consegui consultar a chave registrada na Hetzner"
		fi
	fi
else
	fail "chave pública SSH não encontrada (CDW_SSH_PUBLIC_KEY_FILE)"
fi

pass_file="$(expand_path "${CDW_STATE_PASSPHRASE_FILE:-~/.config/cdw/state-passphrase}")"
if [[ -f "$pass_file" ]]; then
	mode="$(file_mode "$pass_file")"
	if [[ "${mode: -2}" == "00" ]]; then ok "arquivo da passphrase do estado protegido"; else fail "passphrase do estado com permissão $mode; use chmod 600"; fi
	pass_len="$(head -n1 "$pass_file" | tr -d '\n' | wc -c)"
	if ((pass_len < 16)); then fail "passphrase do estado com menos de 16 caracteres"; fi
else
	fail "arquivo da passphrase do estado não encontrado (CDW_STATE_PASSPHRASE_FILE)"
fi

echo
if ((problems > 0)); then
	echo "Preflight: $problems problema(s) encontrado(s)."
	exit 1
fi
echo "Preflight: tudo pronto."
