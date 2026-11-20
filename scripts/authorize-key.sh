#!/usr/bin/env bash
# make authorize-key [CHAVE=arquivo.pub]: autoriza mais uma chave PÚBLICA na
# VM atual (~/.ssh/authorized_keys do usuário dev), sem recriar a VM. Entra
# com a chave que já funciona (a do .env). Sem CHAVE, usa a chave do Windows
# (/mnt/c/Users/<você>/.ssh/id_ed25519.pub), a que o VS Code usa.
# Idempotente: autorizar a mesma chave de novo não duplica a linha.
set -Eeuo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/tf.sh
source "$CDW_ROOT/scripts/lib/tf.sh"
# shellcheck source=scripts/lib/sshkey.sh
source "$CDW_ROOT/scripts/lib/sshkey.sh"

cdw_load_config

key="${1:-}"
if [[ -z "$key" ]]; then
	win_dir="$(cdw_windows_ssh_dir)"
	[[ -n "$win_dir" ]] || die "não achei a chave do Windows; informe o arquivo: make authorize-key CHAVE=/mnt/c/Users/<você>/.ssh/id_ed25519.pub"
	key="$win_dir/id_ed25519.pub"
fi
key="$(expand_path "$key")"
[[ -f "$key" ]] || die "arquivo não encontrado: $key"
if grep -q 'PRIVATE KEY' "$key"; then
	die "$key contém uma chave PRIVADA; aponte para o arquivo .pub"
fi
line="$(cdw_pubkey_line "$key")" || die "$key não é uma única chave pública OpenSSH válida"

cdw_setup_encryption
tf_init
tf_has_server || die "nenhuma VM no estado local; a próxima (make up) já nasce com a chave do .env"
server_id="$(tf_output server_id)"
target="$(tf_output username)@$(tf_output ipv4)"

log "autorizando na VM ($target) a chave $key"
log "  MD5 $(cdw_key_fp "$key" md5) | SHA256 $(cdw_key_fp "$key" sha256)"
# A linha já foi validada por cdw_pubkey_line (só [A-Za-z0-9+/=@.-] e um
# espaço), então pode ir entre aspas simples no comando remoto.
# shellcheck disable=SC2016 # as variáveis "$f" são expandidas na VM
remote='umask 077 && mkdir -p ~/.ssh && f=~/.ssh/authorized_keys && touch "$f" &&
if grep -qF -- '"'$line'"' "$f"; then echo cdw-ja-autorizada;
else printf "%s cdw-authorize-key\n" '"'$line'"' >>"$f" && echo cdw-autorizada; fi'
out="$(cdw_ssh "$server_id" "$target" "$remote")" ||
	die "não consegui entrar na VM com a chave do .env ($CDW_SSH_PRIVATE_KEY_FILE). Veja \"A VM não aceita nenhuma chave minha\" em docs/ssh-key.md"
case "$out" in
*cdw-ja-autorizada*) log "a chave já estava autorizada; nada mudou." ;;
*cdw-autorizada*) log "chave autorizada. Teste no PowerShell: ssh cdw" ;;
*) die "resposta inesperada da VM; confira com make key-check" ;;
esac
log "Isso vale só para esta VM. Para toda VM nova nascer com ela, veja \"Chave SSH definitiva\" em docs/ssh-key.md."
