#!/usr/bin/env bash
# make backup: dump do PostgreSQL/Redis, snapshot restic criptografado num
# destino fora da Hetzner (ver docs/adr/0003-persistencia-e-backup.md),
# retenção configurável e verificação de integridade. Não destrói nada.
set -Eeuo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/tf.sh
source "$CDW_ROOT/scripts/lib/tf.sh"

mode=full
if [[ "${1:-}" == "--state-only" ]]; then
	# Usado por make up: só copia o estado OpenTofu, sem snapshot de ~/work,
	# para não criar um snapshot "cdw" vazio que viraria o latest do restore.
	mode=state
fi

cdw_load_config

: "${RESTIC_REPOSITORY:?defina RESTIC_REPOSITORY no .env local (ver docs/adr/0003-persistencia-e-backup.md)}"
restic_password_file="$(expand_path "${RESTIC_PASSWORD_FILE:-~/.config/cdw/restic-password}")"
[[ -f "$restic_password_file" ]] || die "senha do restic não encontrada em $restic_password_file"
restic_password_mode="$(file_mode "$restic_password_file")"
[[ "${restic_password_mode: -2}" == "00" ]] || die "$restic_password_file tem permissão $restic_password_mode; use: chmod 600 $restic_password_file"
restic_password="$(head -n1 "$restic_password_file")"
((${#restic_password} >= 16)) || die "a senha do restic precisa ter pelo menos 16 caracteres"

if [[ "$RESTIC_REPOSITORY" == s3:* ]]; then
	: "${AWS_ACCESS_KEY_ID:?repositório s3: exige AWS_ACCESS_KEY_ID no .env local}"
	: "${AWS_SECRET_ACCESS_KEY:?repositório s3: exige AWS_SECRET_ACCESS_KEY no .env local}"
fi

cdw_setup_encryption
tf_init
tf_has_server || die "nenhuma VM no estado local; rode make up primeiro"

server_id="$(tf_output server_id)"
ip="$(tf_output ipv4)"
user="$(tf_output username)"

cdw_ssh "$server_id" "$user@$ip" true 2>/dev/null || die "SSH não respondeu em $ip; confira make status"

log "enviando credenciais do restic por stdin (nunca gravadas localmente nem impressas)"
{
	printf 'RESTIC_REPOSITORY=%s\n' "$(shell_quote "$RESTIC_REPOSITORY")"
	printf 'RESTIC_PASSWORD=%s\n' "$(shell_quote "$restic_password")"
	[[ -n "${AWS_ACCESS_KEY_ID:-}" ]] && printf 'AWS_ACCESS_KEY_ID=%s\n' "$(shell_quote "$AWS_ACCESS_KEY_ID")"
	[[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]] && printf 'AWS_SECRET_ACCESS_KEY=%s\n' "$(shell_quote "$AWS_SECRET_ACCESS_KEY")"
	printf 'AWS_DEFAULT_REGION=%s\n' "$(shell_quote "${AWS_DEFAULT_REGION:-auto}")"
	printf 'CDW_BACKUP_KEEP_DAILY=%s\n' "$(shell_quote "${CDW_BACKUP_KEEP_DAILY:-7}")"
	printf 'CDW_BACKUP_KEEP_WEEKLY=%s\n' "$(shell_quote "${CDW_BACKUP_KEEP_WEEKLY:-4}")"
	printf 'CDW_BACKUP_KEEP_MONTHLY=%s\n' "$(shell_quote "${CDW_BACKUP_KEEP_MONTHLY:-6}")"
	printf 'CDW_BACKUP_MODE=%s\n' "$mode"
} | cdw_ssh "$server_id" "$user@$ip" "umask 077 && cat > ~/.cdw-backup.env"

# O arquivo de estado já está criptografado pelo OpenTofu (ADR-0002); vai para
# o mesmo repositório restic com a tag cdw-state (ADR-0007).
log "enviando o estado OpenTofu criptografado para cópia externa"
cdw_ssh "$server_id" "$user@$ip" "umask 077 && mkdir -p ~/.cdw-state-upload && cat > ~/.cdw-state-upload/terraform.tfstate" \
	<"$CDW_STATE_DIR/terraform.tfstate"

if [[ "$mode" == "state" ]]; then
	log "copiando o estado OpenTofu para o repositório restic"
	cdw_ssh "$server_id" "$user@$ip" "bash -s" <"$CDW_ROOT/scripts/lib/backup-remote.sh"
	log "cópia do estado concluída"
	exit 0
fi

log "rodando backup na VM (dumps, restic backup, forget --prune, check)"
cdw_ssh "$server_id" "$user@$ip" "bash -s" <"$CDW_ROOT/scripts/lib/backup-remote.sh"
log "backup concluído"
