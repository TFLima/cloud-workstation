#!/usr/bin/env bash
# Testa scripts/lib/backup-remote.sh com restic e docker falsos: sem make
# deploy (sem ~/compose), o backup de ~/work e dos dotfiles precisa acontecer
# mesmo assim, com manifesto válido e credenciais apagadas ao final; e a cópia
# do estado OpenTofu vai para um snapshot próprio (tag cdw-state).
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/home/work" "$TMP/home/.claude"
cat >"$TMP/bin/restic" <<'STUB'
#!/usr/bin/env bash
echo "restic $*" >>"$CDW_TEST_LOG"
case "$1" in
version) echo "restic 0.16.4" ;;
snapshots) [[ " $* " == *" --json "* ]] && echo '[{"time":"2026-10-18T00:00:00Z","short_id":"abc123"}]' ;;
backup)
	for p in "$@"; do
		[[ -f "$p/manifest.json" ]] && cp "$p/manifest.json" "$CDW_TEST_MANIFEST"
		[[ -d "$p/agent-home" ]] && cp -a "$p/agent-home" "$CDW_TEST_AGENT_COPY"
	done
	;;
esac
exit 0
STUB
cat >"$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >>"$CDW_TEST_LOG"
[[ "$1" == "--version" ]] && echo "Docker version 29.9.1"
exit 0
STUB
# sudo falso: ignora -n e executa o comando; o teste não troca de usuário.
cat >"$TMP/bin/sudo" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "-n" ]] && shift
exec "$@"
STUB
chmod +x "$TMP/bin/restic" "$TMP/bin/docker" "$TMP/bin/sudo"

mkdir -p "$TMP/agent/.claude" "$TMP/agent/.codex"
echo '{"token":"falso"}' >"$TMP/agent/.claude/.credentials.json"

write_env() {
	printf 'RESTIC_REPOSITORY=/tmp/repo-falso\nRESTIC_PASSWORD=teste\nCDW_BACKUP_MODE=%s\n' "$1" >"$TMP/home/.cdw-backup.env"
	mkdir -p "$TMP/home/.cdw-state-upload"
	echo '{"encrypted":"falso"}' >"$TMP/home/.cdw-state-upload/terraform.tfstate"
	: >"$TMP/log"
}

run_remote() {
	HOME="$TMP/home" PATH="$TMP/bin:$PATH" CDW_TEST_LOG="$TMP/log" CDW_TEST_MANIFEST="$TMP/manifest.json" \
		CDW_AGENT_HOME="$TMP/agent" CDW_TEST_AGENT_COPY="$TMP/agent-copy" \
		bash "$ROOT/scripts/lib/backup-remote.sh" 2>&1
}

echo "backup sem make deploy:"

write_env full
status=0
out="$(run_remote)" || status=$?
assert_status 0 "$status" "termina com sucesso sem ~/compose"
assert_contains "$out" "pulando dumps" "avisa que os dumps foram pulados"
log="$(cat "$TMP/log")"
assert_contains "$log" "restic backup $TMP/home/work" "inclui ~/work no snapshot"
assert_contains "$log" "$TMP/home/.claude" "inclui os dotfiles do próprio operador"
assert_contains "$log" "restic check" "verifica a integridade"
assert_not_contains "$log" "docker compose" "não chama o Compose"
assert_status "[]" "$(jq -c .dumps "$TMP/manifest.json")" "manifesto lista dumps vazio como []"
assert_contains "$out" "copiando o estado dos agentes" "avisa que copiou o estado dos agentes"
if [[ -f "$TMP/agent-copy/.claude/.credentials.json" ]]; then pass "snapshot inclui ~/.claude do usuário dos agentes"; else flunk "snapshot sem ~/.claude do usuário dos agentes"; fi
if [[ -d "$TMP/agent-copy/.codex" ]]; then pass "snapshot inclui ~/.codex do usuário dos agentes"; else flunk "snapshot sem ~/.codex do usuário dos agentes"; fi
assert_contains "$log" "restic backup $TMP/home/.cdw-state-upload --tag cdw-state" "copia o estado OpenTofu com a tag cdw-state"
if [[ -e "$TMP/home/.cdw-backup.env" ]]; then flunk "credenciais ficaram na VM"; else pass "credenciais apagadas ao sair"; fi
if [[ -e "$TMP/home/.cdw-state-upload" ]]; then flunk "cópia do estado ficou na VM"; else pass "cópia do estado apagada ao sair"; fi

echo "só o estado (make up):"

write_env state
status=0
out="$(run_remote)" || status=$?
assert_status 0 "$status" "termina com sucesso"
log="$(cat "$TMP/log")"
assert_contains "$log" "--tag cdw-state" "faz o snapshot do estado"
assert_not_contains "$log" "--tag cdw " "não cria snapshot cdw (seria o latest vazio do restore)"
assert_not_contains "$log" "restic forget" "não aplica retenção"
if [[ -e "$TMP/home/.cdw-state-upload" ]]; then flunk "cópia do estado ficou na VM"; else pass "cópia do estado apagada ao sair"; fi

finish
