#!/usr/bin/env bash
# make deploy: sobe (ou atualiza) os serviços do Compose na VM, pelos perfis
# escolhidos em CDW_COMPOSE_PROFILES. Não cria a VM (isso é o make up).
set -Eeuo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/tf.sh
source "$CDW_ROOT/scripts/lib/tf.sh"

cdw_load_config

profiles="${CDW_COMPOSE_PROFILES:-tools}"
IFS=',' read -r -a profile_list <<<"$profiles"
profile_args=()
needs_postgres=0
needs_tools_image=0
for p in "${profile_list[@]}"; do
	profile_args+=(--profile "$p")
	[[ "$p" == "db" || "$p" == "full" ]] && needs_postgres=1
	[[ "$p" == "tools" || "$p" == "full" ]] && needs_tools_image=1
done
if ((needs_tools_image)) && [[ -z "${CDW_TOOLS_IMAGE:-}" ]]; then
	die "perfil tools/full selecionado mas CDW_TOOLS_IMAGE não está definido no .env local"
fi
if ((needs_postgres)) && [[ -z "${POSTGRES_PASSWORD:-}" ]]; then
	die "perfil db/full selecionado mas POSTGRES_PASSWORD não está definido no .env local"
fi

cdw_setup_encryption
tf_init
tf_has_server || die "nenhuma VM no estado local; rode make up primeiro"

server_id="$(tf_output server_id)"
ip="$(tf_output ipv4)"
user="$(tf_output username)"

cdw_ssh "$server_id" "$user@$ip" true 2>/dev/null || die "SSH não respondeu em $ip; confira make status"

remote_dir="/home/$user/compose"
log "enviando docker/compose.yaml para $user@$ip:$remote_dir"
cdw_ssh "$server_id" "$user@$ip" "install -d -m 0700 $remote_dir"

mapfile -t ssh_opts < <(cdw_ssh_opts "$server_id")
scp "${ssh_opts[@]}" "$CDW_ROOT/docker/compose.yaml" "$user@$ip:$remote_dir/compose.yaml"

# .env remoto: só por stdin via SSH, nunca gravado em disco local nem impresso.
# O Compose interpola "$" no .env (variable interpolation); um valor com "$"
# (comum em senha gerada) precisa virar "$$" para chegar literal ao serviço.
env_escape() { printf '%s' "$1" | sed 's/\$/$$/g'; }
{
	printf 'CDW_PROJECTS_DIR=%s\n' "$(env_escape "${CDW_PROJECTS_DIR:-/home/$user/work}")"
	if [[ -n "${CDW_TOOLS_IMAGE:-}" ]]; then
		printf 'CDW_TOOLS_IMAGE=%s\n' "$(env_escape "$CDW_TOOLS_IMAGE")"
	fi
	if ((needs_postgres)); then
		printf 'POSTGRES_USER=%s\n' "$(env_escape "${POSTGRES_USER:-dev}")"
		printf 'POSTGRES_PASSWORD=%s\n' "$(env_escape "${POSTGRES_PASSWORD:?defina POSTGRES_PASSWORD no .env local (perfil db/full selecionado)}")"
		printf 'POSTGRES_DB=%s\n' "$(env_escape "${POSTGRES_DB:-dev}")"
	fi
} | cdw_ssh "$server_id" "$user@$ip" "cat > $remote_dir/.env && chmod 600 $remote_dir/.env"

log "subindo perfis: $profiles"
cdw_ssh "$server_id" "$user@$ip" "cd $remote_dir && docker compose -f compose.yaml ${profile_args[*]} up -d"
log "serviços no ar. Veja com: make status"
