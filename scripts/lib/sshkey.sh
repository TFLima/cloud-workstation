#!/usr/bin/env bash
# Chave SSH do operador: impressões digitais, chave do Windows (vista do WSL)
# e a chave registrada na Hetzner. Só lida com arquivos .pub; nunca lê nem
# imprime a chave privada.
# Requer scripts/lib/common.sh carregado antes (e scripts/lib/hcloud.sh para
# cdw_hetzner_key_fp).

# Impressão digital de um arquivo .pub, sem o prefixo: cdw_key_fp <arquivo> [md5|sha256]
# MD5 é o formato que o console e a API da Hetzner mostram.
cdw_key_fp() {
	local file="$1" hash="${2:-sha256}" fp
	fp="$(ssh-keygen -l -E "$hash" -f "$file" 2>/dev/null | awk '{print $2}')" || return 1
	[[ -n "$fp" ]] || return 1
	printf '%s\n' "${fp#*:}"
}

# Retorna 0 se estiver rodando dentro do WSL.
cdw_is_wsl() {
	[[ -n "${WSL_DISTRO_NAME:-}" ]] && return 0
	grep -qi microsoft /proc/version 2>/dev/null
}

# Pasta .ssh do Windows vista do WSL (ex.: /mnt/c/Users/User/.ssh). Pode ser
# fixada com CDW_WINDOWS_SSH_DIR; senão procura em /mnt/c/Users/*/.ssh uma
# única pasta com id_ed25519.pub. Não imprime nada se não achar (ou se houver
# mais de uma candidata).
cdw_windows_ssh_dir() {
	if [[ -n "${CDW_WINDOWS_SSH_DIR:-}" ]]; then
		[[ -d "$CDW_WINDOWS_SSH_DIR" ]] && printf '%s\n' "${CDW_WINDOWS_SSH_DIR%/}"
		return 0
	fi
	cdw_is_wsl || return 0
	local d found=()
	for d in /mnt/c/Users/*/.ssh; do
		[[ -f "$d/id_ed25519.pub" ]] && found+=("$d")
	done
	((${#found[@]} == 1)) && printf '%s\n' "${found[0]}"
	return 0
}

# Caminho do WSL convertido para o Windows (/mnt/c/Users/x -> C:/Users/x).
# Não imprime nada para caminhos que não estão num disco do Windows.
cdw_windows_path() {
	local p="$1"
	if [[ "$p" =~ ^/mnt/([a-zA-Z])/(.*)$ ]]; then
		printf '%s:/%s\n' "${BASH_REMATCH[1]^^}" "${BASH_REMATCH[2]}"
	fi
}

# Impressão digital MD5 da chave "<nome>-operator" registrada na Hetzner.
# Imprime nada se ela não existir; retorna 1 se a API não respondeu.
cdw_hetzner_key_fp() {
	local name="${TF_VAR_name:-cdw}-operator" json
	json="$(hcloud_get "/ssh_keys?name=$name" 2>/dev/null)" || return 1
	jq -r --arg n "$name" '[.ssh_keys[]? | select(.name == $n)][0].fingerprint // empty' <<<"$json"
}

# "<tipo> <base64>" de um arquivo .pub, sem o comentário, ou retorna 1 se o
# arquivo não for uma única chave pública OpenSSH. Seguro para entrar entre
# aspas simples num comando remoto (só letras, dígitos e + / = @ . -).
cdw_pubkey_line() {
	local file="$1" line
	[[ -f "$file" ]] || return 1
	grep -q 'PRIVATE KEY' "$file" && return 1
	(($(grep -c . "$file") == 1)) || return 1
	line="$(awk 'NF >= 2 {print $1" "$2; exit}' "$file")"
	[[ "$line" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-[a-z0-9@.-]+)\ [A-Za-z0-9+/]+=*$ ]] || return 1
	ssh-keygen -l -f "$file" >/dev/null 2>&1 || return 1
	printf '%s\n' "$line"
}
