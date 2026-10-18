#!/usr/bin/env bash
# Executado na VM por scripts/backup.sh (via "ssh ... 'bash -s' < este arquivo").
# Credenciais do restic chegam em ~/.cdw-backup.env (gravado só por stdin,
# nunca em disco local nem impresso); este script as apaga ao sair, com ou
# sem sucesso.
set -Eeuo pipefail

ENV_FILE="$HOME/.cdw-backup.env"
[[ -f "$ENV_FILE" ]] || {
	echo "arquivo de credenciais do backup não encontrado ($ENV_FILE)" >&2
	exit 1
}
# shellcheck source=/dev/null
source "$ENV_FILE"

# Cópia do estado OpenTofu (já criptografado pelo OpenTofu no notebook; a VM
# nunca vê a passphrase), enviada por scripts/backup.sh. Ver ADR-0007.
STATE_UPLOAD="$HOME/.cdw-state-upload"

STAGE="$(mktemp -d "$HOME/.cdw-backup-stage.XXXXXX")"
cleanup() {
	shred -u "$ENV_FILE" 2>/dev/null || rm -f "$ENV_FILE"
	rm -rf "$STAGE" "$STATE_UPLOAD"
}
trap cleanup EXIT

export RESTIC_REPOSITORY RESTIC_PASSWORD
[[ -n "${AWS_ACCESS_KEY_ID:-}" ]] && export AWS_ACCESS_KEY_ID
[[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]] && export AWS_SECRET_ACCESS_KEY
[[ -n "${AWS_DEFAULT_REGION:-}" ]] && export AWS_DEFAULT_REGION
: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY ausente}"
: "${RESTIC_PASSWORD:?RESTIC_PASSWORD ausente}"

backup_state() {
	if [[ -f "$STATE_UPLOAD/terraform.tfstate" ]]; then
		echo "[backup] snapshot do estado OpenTofu criptografado (tag cdw-state)"
		restic backup "$STATE_UPLOAD" --tag cdw-state --host "$(hostname)"
	else
		echo "[backup] estado OpenTofu não foi enviado; pulando cópia do estado"
	fi
}

if [[ "${CDW_BACKUP_MODE:-full}" == "state" ]]; then
	echo "[backup] repositório restic: inicializando se necessário"
	restic snapshots >/dev/null 2>&1 || restic init
	backup_state
	echo "[backup] concluído: só o estado OpenTofu"
	exit 0
fi

# Sem make deploy não há Compose nem bancos: os dumps são pulados, mas ~/work
# e os dotfiles dos agentes entram no snapshot mesmo assim (make down depende
# deste backup para não exigir CDW_SKIP_BACKUP=1).
COMPOSE_DIR="$HOME/compose"
if [[ ! -d "$COMPOSE_DIR" ]]; then
	echo "[backup] nada implantado em $COMPOSE_DIR; pulando dumps dos bancos"
fi

running() {
	[[ -d "$COMPOSE_DIR" ]] && (cd "$COMPOSE_DIR" && docker compose ps --status running --services 2>/dev/null) | grep -qx "$1"
}

mkdir -p "$STAGE/dumps"
dumps=()

if running postgres; then
	echo "[backup] dump lógico do PostgreSQL (pg_dump -Fc)"
	f="$STAGE/dumps/postgres-$(date -u +%Y%m%dT%H%M%SZ).dump"
	(cd "$COMPOSE_DIR" && docker compose exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB"') >"$f"
	dumps+=("$(basename "$f")")
else
	echo "[backup] serviço postgres não está no ar; pulando dump"
fi

if running redis; then
	echo "[backup] snapshot do Redis (SAVE síncrono + cópia do dump.rdb)"
	(cd "$COMPOSE_DIR" && docker compose exec -T redis redis-cli SAVE) >/dev/null
	f="$STAGE/dumps/redis-$(date -u +%Y%m%dT%H%M%SZ).rdb"
	(cd "$COMPOSE_DIR" && docker compose cp redis:/data/dump.rdb "$f")
	dumps+=("$(basename "$f")")
else
	echo "[backup] serviço redis não está no ar; pulando snapshot"
fi

dumps_json="[]"
if ((${#dumps[@]})); then
	dumps_json="$(printf '"%s",' "${dumps[@]}")"
	dumps_json="[${dumps_json%,}]"
fi
cat >"$STAGE/manifest.json" <<JSON
{
  "date": "$(date -u +%FT%TZ)",
  "hostname": "$(hostname)",
  "bootstrap_version": "$(cat /etc/cdw/bootstrap-version 2>/dev/null || echo desconhecida)",
  "docker_version": "$(docker --version)",
  "restic_version": "$(restic version)",
  "dumps": $dumps_json
}
JSON

backup_paths=("$HOME/work" "$STAGE")
for d in "$HOME/.claude" "$HOME/.codex"; do
	[[ -e "$d" ]] && backup_paths+=("$d")
done

echo "[backup] repositório restic: inicializando se necessário"
restic snapshots >/dev/null 2>&1 || restic init

echo "[backup] enviando snapshot"
restic backup "${backup_paths[@]}" --tag cdw --host "$(hostname)"

backup_state

echo "[backup] retenção (forget --prune)"
# --group-by host,tags (não o padrão "host,paths"): a área de preparo em
# backup_paths tem um nome aleatório (mktemp) a cada execução, então agrupar
# por caminho faria cada snapshot virar seu próprio grupo de 1 e a retenção
# nunca podaria nada.
restic forget --prune --group-by host,tags \
	--keep-daily "${CDW_BACKUP_KEEP_DAILY:-7}" \
	--keep-weekly "${CDW_BACKUP_KEEP_WEEKLY:-4}" \
	--keep-monthly "${CDW_BACKUP_KEEP_MONTHLY:-6}"

echo "[backup] verificação de integridade (amostra de 5% dos dados)"
restic check --read-data-subset=5%

# Não "snapshots --latest 1": por padrão agrupa por host+paths, e o caminho
# da área de preparo muda a cada execução (mktemp) — "--latest 1" devolveria
# um snapshot por grupo, não só o mais recente de verdade. Ordena por data.
short_id="$(restic snapshots --tag cdw --host "$(hostname)" --json | jq -r 'sort_by(.time) | last.short_id // "?"')"
echo "[backup] concluído: snapshot $short_id"
