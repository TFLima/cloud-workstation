#!/usr/bin/env bash
# make win-config: atualiza, direto do WSL, o bloco "Host cdw" do
# C:\Users\<você>\.ssh\config do Windows para a VM atual: IP, usuário, chave
# (IdentityFile no caminho do Windows), known_hosts próprio desta VM (copiado
# do WSL, já verificado) e os túneis de CDW_LOCAL_FORWARDS. As demais linhas
# do bloco e o resto do arquivo são mantidos; a versão anterior fica em
# config.bak-cdw. O make up chama isto sozinho no fim (CDW_WINDOWS_SSH_CONFIG=0
# desliga). Não imprime nem copia chave privada.
set -Eeuo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/tf.sh
source "$CDW_ROOT/scripts/lib/tf.sh"
# shellcheck source=scripts/lib/sshkey.sh
source "$CDW_ROOT/scripts/lib/sshkey.sh"

cdw_load_config
alias_name="${CDW_SSH_HOST_ALIAS:-cdw}"
[[ "$alias_name" =~ ^[A-Za-z0-9._-]+$ ]] || die "CDW_SSH_HOST_ALIAS inválido: use só letras, dígitos, . _ -"

win_dir="$(cdw_windows_ssh_dir)"
[[ -n "$win_dir" ]] || die "pasta .ssh do Windows não encontrada; defina CDW_WINDOWS_SSH_DIR=/mnt/c/Users/<você>/.ssh no .env"

# Túneis: "8000" ou "8000:8000" ou "18000:8000" (local:remota), separados por vírgula.
forwards=()
if [[ -n "${CDW_LOCAL_FORWARDS:-}" ]]; then
	IFS=',' read -r -a items <<<"${CDW_LOCAL_FORWARDS// /}"
	for item in "${items[@]}"; do
		[[ -z "$item" ]] && continue
		[[ "$item" =~ ^([0-9]{1,5})(:([0-9]{1,5}))?$ ]] || die "CDW_LOCAL_FORWARDS inválido em '$item' (use 8000 ou 18000:8000)"
		forwards+=("LocalForward ${BASH_REMATCH[1]} 127.0.0.1:${BASH_REMATCH[3]:-${BASH_REMATCH[1]}}")
	done
fi

cdw_setup_encryption
tf_init
tf_has_server || die "nenhuma VM no estado local; use make up"
server_id="$(tf_output server_id)"
ip="$(tf_output ipv4)"
user="$(tf_output username)"

# known_hosts próprio da VM: o do WSL foi gravado na primeira conexão do
# make up; copiá-lo evita "REMOTE HOST IDENTIFICATION HAS CHANGED" quando a
# Hetzner reaproveita um IP que já esteve no known_hosts geral do Windows.
kh_name="known_hosts.cdw.$server_id"
if [[ -s "$CDW_STATE_DIR/known_hosts.$server_id" ]]; then
	cp "$CDW_STATE_DIR/known_hosts.$server_id" "$win_dir/$kh_name"
else
	warn "o WSL ainda não conhece a chave de host desta VM; a primeira conexão do Windows vai aceitá-la e fixá-la"
fi

# A chave do .env, se ela estiver num disco do Windows (/mnt/c/...); senão a
# chave padrão do Windows, se existir; senão "~" (expandido pelo Windows).
identity="$(cdw_windows_path "$CDW_SSH_PRIVATE_KEY_FILE")"
if [[ -z "$identity" && -f "$win_dir/id_ed25519" ]]; then
	identity="$(cdw_windows_path "$win_dir/id_ed25519")"
fi
identity="${identity:-~/.ssh/id_ed25519}"
[[ "$identity" == *" "* ]] && identity="\"$identity\""

managed=(
	"HostName $ip"
	"User $user"
	"IdentityFile $identity"
	"IdentitiesOnly yes"
	"UserKnownHostsFile ~/.ssh/$kh_name"
	"StrictHostKeyChecking accept-new"
	"ServerAliveInterval 30"
)
((${#forwards[@]} > 0)) && managed+=("${forwards[@]}")

config="$win_dir/config"
new="$(mktemp)"
trap 'rm -f "$new"' EXIT
# Remove as chaves gerenciadas do bloco (e as LocalForward, se CDW_LOCAL_FORWARDS
# estiver definido), mantendo o resto; acrescenta o bloco se ele não existir.
# O arquivo é reescrito no lugar (cat >), para manter as permissões do Windows.
if [[ -f "$config" ]]; then tr -d '\r' <"$config"; fi |
	awk -v alias="$alias_name" -v managed="$(printf '%s\n' "${managed[@]}")" -v own_fwd="${#forwards[@]}" '
	BEGIN {
		n = split(managed, m, "\n")
		keys["hostname"]; keys["user"]; keys["identityfile"]; keys["identitiesonly"]
		keys["userknownhostsfile"]; keys["stricthostkeychecking"]; keys["serveraliveinterval"]
		if (own_fwd > 0) keys["localforward"]
	}
	function emit_managed(   i) { for (i = 1; i <= n; i++) if (m[i] != "") print "    " m[i] }
	{
		line = $0
		if (match(tolower(line), /^[ \t]*(host|match)[ \t]/)) {
			inblock = 0
			split(line, f, /[ \t]+/)
			first = (f[1] == "") ? f[2] : f[1]
			rest = line; sub(/^[ \t]*[A-Za-z]+[ \t]+/, "", rest); sub(/[ \t]+$/, "", rest)
			if (tolower(first) == "host" && rest == alias) {
				inblock = 1; found = 1
				print "Host " alias
				emit_managed()
				next
			}
		}
		if (inblock) {
			k = line; sub(/^[ \t]+/, "", k); sub(/[ \t=].*$/, "", k)
			if (tolower(k) in keys) next
		}
		print line
	}
	END {
		if (!found) {
			if (NR > 0 && line != "") print ""
			print "Host " alias
			emit_managed()
		}
	}' >"$new"

if [[ -f "$config" ]]; then
	cp "$config" "$win_dir/config.bak-cdw"
	cmp -s <(tr -d '\r' <"$config") "$new" && {
		log "Host $alias_name no Windows já aponta para $ip; nada mudou"
		exit 0
	}
fi
cat "$new" >"$config"
log "Host $alias_name no Windows atualizado: $ip (VM $server_id), known_hosts próprio${forwards:+, túneis: ${CDW_LOCAL_FORWARDS}}"
log "No VS Code: F1 > Remote-SSH: Connect to Host... > $alias_name"
