#!/usr/bin/env bash
# make restore: restaura o snapshot restic (CDW_RESTORE_SNAPSHOT, padrão o
# mais recente) na VM atual — ~/work, dotfiles dos agentes e os bancos de
# dados. Sobrescreve dados da VM; exige confirmação explícita digitada.
set -Eeuo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/tf.sh
source "$CDW_ROOT/scripts/lib/tf.sh"

cdw_load_config

: "${RESTIC_REPOSITORY:?defina RESTIC_REPOSITORY no .env local (ver docs/adr/0003-persistencia-e-backup.md)}"
restic_password_file="$(expand_path "${RESTIC_PASSWORD_FILE:-~/.config/cdw/restic-password}")"
[[ -f "$restic_password_file" ]] || die "senha do restic não encontrada em $restic_password_file"
restic_password_mode="$(file_mode "$restic_password_file")"
[[ "${restic_password_mode: -2}" == "00" ]] || die "$restic_password_file tem permissão $restic_password_mode; use: chmod 600 $restic_password_file"
restic_password="$(head -n1 "$restic_password_file")"

if [[ "$RESTIC_REPOSITORY" == s3:* ]]; then
	: "${AWS_ACCESS_KEY_ID:?repositório s3: exige AWS_ACCESS_KEY_ID no .env local}"
	: "${AWS_SECRET_ACCESS_KEY:?repositório s3: exige AWS_SECRET_ACCESS_KEY no .env local}"
fi

snapshot="${CDW_RESTORE_SNAPSHOT:-latest}"
[[ "$snapshot" =~ ^[A-Za-z0-9]+$ ]] || die "CDW_RESTORE_SNAPSHOT inválido: $snapshot"

cdw_setup_encryption
tf_init
tf_has_server || die "nenhuma VM no estado local; rode make up primeiro"

server_id="$(tf_output server_id)"
ip="$(tf_output ipv4)"
user="$(tf_output username)"

cdw_ssh "$server_id" "$user@$ip" true 2>/dev/null || die "SSH não respondeu em $ip; confira make status"

echo "ATENÇÃO: isso sobrescreve ~/work, dotfiles dos agentes e os bancos de dados"
echo "na VM atual ($ip) com o snapshot '$snapshot' do repositório restic."
if [[ "${CDW_CONFIRM:-}" != "restaurar" ]]; then
	read -r -p "Digite 'restaurar' para continuar: " answer
	[[ "$answer" == "restaurar" ]] || die "cancelado; nada foi restaurado"
fi

log "enviando credenciais do restic por stdin (nunca gravadas localmente nem impressas)"
{
	printf 'RESTIC_REPOSITORY=%s\n' "$(shell_quote "$RESTIC_REPOSITORY")"
	printf 'RESTIC_PASSWORD=%s\n' "$(shell_quote "$restic_password")"
	[[ -n "${AWS_ACCESS_KEY_ID:-}" ]] && printf 'AWS_ACCESS_KEY_ID=%s\n' "$(shell_quote "$AWS_ACCESS_KEY_ID")"
	[[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]] && printf 'AWS_SECRET_ACCESS_KEY=%s\n' "$(shell_quote "$AWS_SECRET_ACCESS_KEY")"
	printf 'AWS_DEFAULT_REGION=%s\n' "$(shell_quote "${AWS_DEFAULT_REGION:-auto}")"
} | cdw_ssh "$server_id" "$user@$ip" "umask 077 && cat > ~/.cdw-backup.env"

log "restaurando na VM (pode levar alguns minutos)"
cdw_ssh "$server_id" "$user@$ip" "CDW_RESTORE_SNAPSHOT=$snapshot bash -s" <"$CDW_ROOT/scripts/lib/restore-remote.sh"
log "restore concluído"
