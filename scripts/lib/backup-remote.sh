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

STAGE="$(mktemp -d "$HOME/.cdw-backup-stage.XXXXXX")"
cleanup() {
	shred -u "$ENV_FILE" 2>/dev/null || rm -f "$ENV_FILE"
	rm -rf "$STAGE"
}
trap cleanup EXIT

export RESTIC_REPOSITORY RESTIC_PASSWORD
[[ -n "${AWS_ACCESS_KEY_ID:-}" ]] && export AWS_ACCESS_KEY_ID
[[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]] && export AWS_SECRET_ACCESS_KEY
[[ -n "${AWS_DEFAULT_REGION:-}" ]] && export AWS_DEFAULT_REGION
: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY ausente}"
: "${RESTIC_PASSWORD:?RESTIC_PASSWORD ausente}"

COMPOSE_DIR="$HOME/compose"
[[ -d "$COMPOSE_DIR" ]] || {
	echo "nada implantado em $COMPOSE_DIR; rode make deploy antes de make backup" >&2
	exit 1
}

running() {
	(cd "$COMPOSE_DIR" && docker compose ps --status running --services 2>/dev/null) | grep -qx "$1"
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

dumps_json="$(printf '"%s",' "${dumps[@]}")"
dumps_json="[${dumps_json%,}]"
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

echo "[backup] retenção (forget --prune)"
restic forget --prune \
	--keep-daily "${CDW_BACKUP_KEEP_DAILY:-7}" \
	--keep-weekly "${CDW_BACKUP_KEEP_WEEKLY:-4}" \
	--keep-monthly "${CDW_BACKUP_KEEP_MONTHLY:-6}"

echo "[backup] verificação de integridade (amostra de 5% dos dados)"
restic check --read-data-subset=5%

short_id="$(restic snapshots --tag cdw --host "$(hostname)" --latest 1 --json | jq -r '.[0].short_id // "?"')"
echo "[backup] concluído: snapshot $short_id"
