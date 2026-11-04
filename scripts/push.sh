#!/usr/bin/env bash
# make push: copia arquivos ou pastas locais para ~/work na VM (ou uma
# subpasta dele), descobrindo o IP atual pelo estado OpenTofu.
# Uso: bash scripts/push.sh [-d subpasta] caminho [caminho...]
#      make push ORIGEM="arquivo pasta" DESTINO=subpasta
# A chave de host é conferida com o known_hosts próprio da VM (o mesmo do
# make connect); nada de desligar a verificação.
set -Eeuo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/tf.sh
source "$CDW_ROOT/scripts/lib/tf.sh"

usage() {
	echo "Uso: bash scripts/push.sh [-d subpasta] caminho [caminho...]" >&2
	echo "     make push ORIGEM=\"arquivo pasta\" [DESTINO=subpasta]" >&2
	exit 2
}

dest=""
while getopts ':d:h' opt; do
	case "$opt" in
	d) dest="$OPTARG" ;;
	*) usage ;;
	esac
done
shift $((OPTIND - 1))
(($# > 0)) || usage

dest="${dest%/}"
cdw_valid_work_subdir "$dest" ||
	die "subpasta inválida: '$dest' (use um caminho relativo a ~/work, sem '..' nem espaços)"
for p in "$@"; do
	[[ -e "$p" ]] || die "não encontrado: $p"
done

cdw_load_config
cdw_setup_encryption
tf_init
tf_has_server || die "nenhuma VM no estado local; use make up"

server_id="$(tf_output server_id)"
ip="$(tf_output ipv4)"
user="$(tf_output username)"
remote="/home/$user/work${dest:+/$dest}"

mapfile -t opts < <(cdw_ssh_opts "$server_id")
log "destino: $user@$ip:$remote/"
cdw_ssh "$server_id" "$user@$ip" "mkdir -p -- '$remote'"
scp "${opts[@]}" -r -- "$@" "$user@$ip:$remote/"
log "copiado: $* -> $remote/"
