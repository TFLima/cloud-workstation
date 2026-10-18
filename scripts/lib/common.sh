#!/usr/bin/env bash
# Funções compartilhadas pelos scripts do Cloud Dev Workstation.
# Uso: source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# Regra: nenhuma função imprime o valor de variáveis sensíveis.

CDW_ROOT="${CDW_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export CDW_ROOT

log() { printf '[cdw] %s\n' "$*" >&2; }
warn() { printf '[cdw] AVISO: %s\n' "$*" >&2; }
die() {
	printf '[cdw] ERRO: %s\n' "$*" >&2
	exit 1
}

# Interrompe com código 2 para etapas ainda não implementadas.
not_implemented() {
	printf '[cdw] %s ainda não foi implementado (previsto na %s).\n' "$1" "$2" >&2
	exit 2
}

# Expande "~/" no início de um caminho sem usar eval.
expand_path() {
	local p="$1"
	case "$p" in
	\~/*) printf '%s/%s\n' "$HOME" "${p#\~/}" ;;
	*) printf '%s\n' "$p" ;;
	esac
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

# Retorna 0 se a variável estiver definida e não vazia; nunca imprime o valor.
env_is_set() {
	local name="$1"
	[[ -n "${!name:-}" ]]
}

# Permissões em octal de um arquivo (GNU stat ou BSD stat).
file_mode() {
	stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

# Carrega um arquivo .env (KEY=VALUE) sem executá-lo como shell.
# Recusa arquivos legíveis por grupo/outros.
load_env_file() {
	local file="$1" line key value mode
	[[ -f "$file" ]] || return 0
	mode="$(file_mode "$file")"
	if [[ "${mode: -2}" != "00" ]]; then
		die "$file tem permissão $mode; use: chmod 600 $file"
	fi
	while IFS= read -r line || [[ -n "$line" ]]; do
		[[ -z "$line" || "$line" == \#* ]] && continue
		[[ "$line" == *=* ]] || continue
		key="${line%%=*}"
		value="${line#*=}"
		[[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "chave inválida em $file"
		# Variáveis já exportadas no ambiente têm precedência.
		if [[ -z "${!key:-}" ]]; then
			export "$key=$value"
		fi
	done <"$file"
}

# Escolhe o binário de IaC: OpenTofu primeiro, Terraform como alternativa.
tf_bin() {
	if [[ -n "${CDW_TF_BIN:-}" ]]; then
		printf '%s\n' "$CDW_TF_BIN"
	elif has_cmd tofu; then
		printf 'tofu\n'
	elif has_cmd terraform; then
		printf 'terraform\n'
	else
		return 1
	fi
}
