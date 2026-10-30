#!/usr/bin/env bash
# Executado na VM por scripts/restore.sh (via "ssh ... 'bash -s' < este arquivo").
# Restaura o snapshot restic (CDW_RESTORE_SNAPSHOT, padrão "latest") para uma
# área de preparo e só então aplica sobre ~/work, dotfiles dos agentes e os
# bancos de dados — nunca restaura direto por cima do que já existe.
set -Eeuo pipefail

ENV_FILE="$HOME/.cdw-backup.env"
[[ -f "$ENV_FILE" ]] || {
	echo "arquivo de credenciais do restore não encontrado ($ENV_FILE)" >&2
	exit 1
}
# shellcheck source=/dev/null
source "$ENV_FILE"

STAGE="$(mktemp -d "$HOME/.cdw-restore-stage.XXXXXX")"
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

snapshot="${CDW_RESTORE_SNAPSHOT:-latest}"

# make up restaura sozinho só se já houver dados salvos: num repositório novo
# (primeiro make up, ou só com a cópia do estado, tag cdw-state) não há o que
# restaurar e isso não é erro. Qualquer outra falha (credenciais, rede) é.
if [[ "${CDW_RESTORE_IF_PRESENT:-0}" == "1" ]]; then
	if snaps="$(restic snapshots --tag cdw --host "$(hostname)" --json 2>"$STAGE/snapshots.err")"; then
		count="$(jq 'length' <<<"$snaps")"
	else
		if grep -qiE 'does not exist|no such file or directory' "$STAGE/snapshots.err"; then
			count=0
		else
			cat "$STAGE/snapshots.err" >&2
			echo "[restore] não foi possível consultar o repositório restic" >&2
			exit 1
		fi
	fi
	if [[ "$count" == "0" ]]; then
		echo "[restore] concluído: nenhum snapshot de dados (tag cdw) no repositório; nada a restaurar"
		exit 0
	fi
fi

echo "[restore] restaurando snapshot '$snapshot' (tag cdw, host $(hostname)) para a área de preparo"
restic restore "$snapshot" --target "$STAGE" --tag cdw --host "$(hostname)"

restored_home="$STAGE$HOME"
manifest="$(find "$restored_home" -maxdepth 2 -name manifest.json 2>/dev/null | head -n1)"
if [[ -n "$manifest" ]]; then
	backed_version="$(jq -r '.bootstrap_version // "desconhecida"' "$manifest")"
	current_version="$(cat /etc/cdw/bootstrap-version 2>/dev/null || echo desconhecida)"
	echo "[restore] manifesto do snapshot: $(cat "$manifest")"
	if [[ "$backed_version" != "$current_version" ]]; then
		echo "[restore] AVISO: snapshot feito com bootstrap '$backed_version'; VM atual está em '$current_version' — confira migrações/compatibilidade antes de confiar no restore" >&2
	fi
	dumps_dir="$(dirname "$manifest")/dumps"
else
	echo "[restore] AVISO: manifesto não encontrado no snapshot; pulando checagem de versões" >&2
	dumps_dir=""
fi

if [[ -d "$restored_home/work" ]]; then
	echo "[restore] restaurando ~/work (mescla; não apaga arquivos que não estejam no snapshot)"
	install -d -m 0755 "$HOME/work"
	cp -a "$restored_home/work/." "$HOME/work/"
	# Snapshots de antes do ADR-0008 trazem ~/work 0755 e arquivos do grupo do
	# operador; o cp -a acima também copia os atributos do diretório "." por cima
	# dos 2775 do bootstrap. Reaplica o grupo compartilhado, setgid e a ACL
	# padrão, senão o agente não consegue gravar no que foi restaurado.
	WORK_GROUP="${CDW_WORK_GROUP:-work}"
	if getent group "$WORK_GROUP" >/dev/null; then
		chgrp -R "$WORK_GROUP" "$HOME/work"
		chmod -R g+rwX "$HOME/work"
		find "$HOME/work" -type d -exec chmod g+s {} +
		find "$HOME/work" -type d -exec setfacl -m g::rwx,d:g::rwx {} + 2>/dev/null ||
			echo "[restore] AVISO: sem suporte a ACL em ~/work; arquivos novos podem ficar só legíveis ao grupo" >&2
	fi
else
	echo "[restore] AVISO: ~/work não está no snapshot" >&2
fi

for d in .claude .codex; do
	if [[ -d "$restored_home/$d" ]]; then
		echo "[restore] restaurando $HOME/$d"
		install -d -m 0700 "$HOME/$d"
		cp -a "$restored_home/$d/." "$HOME/$d/"
	fi
done

# Estado dos agentes (ADR-0008): volta para o home do usuário dos agentes, mas
# extraído COMO esse usuário (nunca como root nem como o operador): o conteúdo
# do snapshot vem de um diretório que o agente controlava, e extraí-lo com os
# privilégios dele limita qualquer symlink ou caminho forjado ao que ele já pode
# escrever. O operador só repassa os bytes por stdin.
AGENT_USER="${CDW_AGENT_USER:-agent}"
AGENT_HOME="${CDW_AGENT_HOME:-$(getent passwd "$AGENT_USER" | cut -d: -f6 || true)}"
agent_tar="$(find "$restored_home" -maxdepth 2 -type f -name agent-home.tar 2>/dev/null | head -n1)"
if [[ -n "$agent_tar" ]]; then
	if [[ -z "$AGENT_HOME" ]]; then
		echo "[restore] AVISO: usuário $AGENT_USER não existe nesta VM; estado dos agentes não restaurado" >&2
	else
		echo "[restore] restaurando o estado dos agentes em $AGENT_HOME (extraído como $AGENT_USER)"
		# A leitura do arquivo é do operador (dono da área de preparo), de propósito.
		# shellcheck disable=SC2024
		sudo -n -u "$AGENT_USER" tar -xpf - -C "$AGENT_HOME" <"$agent_tar"
	fi
fi

COMPOSE_DIR="$HOME/compose"
running() {
	[[ -d "$COMPOSE_DIR" ]] && (cd "$COMPOSE_DIR" && docker compose ps --status running --services 2>/dev/null </dev/null) | grep -qx "$1"
}

pg_dump_file=""
redis_dump_file=""
if [[ -n "$dumps_dir" && -d "$dumps_dir" ]]; then
	pg_dump_file="$(find "$dumps_dir" -maxdepth 1 -name 'postgres-*.dump' 2>/dev/null | sort | tail -n1)"
	redis_dump_file="$(find "$dumps_dir" -maxdepth 1 -name 'redis-*.rdb' 2>/dev/null | sort | tail -n1)"
fi

# A área de preparo (STAGE) é apagada ao sair (trap cleanup); um dump que não
# puder ser aplicado agora é copiado para fora dela antes, para não ser perdido.
PENDING_DIR="$HOME/restore-pending"

if [[ -n "$pg_dump_file" ]]; then
	if running postgres; then
		echo "[restore] restaurando PostgreSQL de $(basename "$pg_dump_file") (pg_restore --clean --if-exists)"
		(cd "$COMPOSE_DIR" && docker compose exec -T postgres sh -c 'pg_restore --clean --if-exists --no-owner -U "$POSTGRES_USER" -d "$POSTGRES_DB"') <"$pg_dump_file"
	else
		install -d -m 0700 "$PENDING_DIR"
		cp -a "$pg_dump_file" "$PENDING_DIR/"
		echo "[restore] AVISO: serviço postgres não está no ar (rode make deploy); dump copiado para $PENDING_DIR/$(basename "$pg_dump_file")" >&2
	fi
else
	echo "[restore] nenhum dump do PostgreSQL no snapshot"
fi

if [[ -n "$redis_dump_file" ]]; then
	if running redis; then
		echo "[restore] restaurando Redis de $(basename "$redis_dump_file")"
		# "stop" (não "restart"): o Redis salva um RDB final ao receber
		# SIGTERM, o que sobrescreveria o dump.rdb copiado se a cópia
		# acontecesse antes do processo realmente parar. Parar primeiro,
		# copiar com o processo já parado e só então iniciar evita a corrida
		# (testado neste sandbox com um container Redis real). O Compose roda
		# o Redis sem AOF (só RDB; ver comentário em docker/compose.yaml), já
		# que com AOF ligado o restart recarrega o AOF em vez do RDB copiado.
		(cd "$COMPOSE_DIR" &&
			docker compose stop redis &&
			docker compose cp "$redis_dump_file" redis:/data/dump.rdb &&
			docker compose start redis) </dev/null
	else
		install -d -m 0700 "$PENDING_DIR"
		cp -a "$redis_dump_file" "$PENDING_DIR/"
		echo "[restore] AVISO: serviço redis não está no ar (rode make deploy); dump copiado para $PENDING_DIR/$(basename "$redis_dump_file")" >&2
	fi
else
	echo "[restore] nenhum dump do Redis no snapshot"
fi

echo "[restore] concluído"
