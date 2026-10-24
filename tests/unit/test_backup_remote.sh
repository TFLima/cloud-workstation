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
		[[ -f "$p/agent-home.tar" ]] && cp "$p/agent-home.tar" "$CDW_TEST_AGENT_COPY"
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
# sudo falso: registra o usuário pedido (-u), ignora as opções e executa o
# comando; o teste não troca de usuário de verdade.
cat >"$TMP/bin/sudo" <<'STUB'
#!/usr/bin/env bash
while [[ "${1:-}" == -* ]]; do
	if [[ "$1" == "-u" ]]; then echo "sudo -u $2" >>"$CDW_TEST_LOG"; shift 2; else shift; fi
done
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
agent_listing="$(tar -tf "$TMP/agent-copy" 2>/dev/null || true)"
assert_contains "$agent_listing" ".claude/.credentials.json" "snapshot inclui o .claude do usuário dos agentes"
assert_contains "$agent_listing" ".codex/" "snapshot inclui o .codex do usuário dos agentes"
assert_contains "$log" "sudo -u agent" "lê o estado dos agentes COMO o usuário dos agentes"
if compgen -G "$TMP/home/.cdw-backup-stage.*" >/dev/null; then flunk "área de preparo ficou na VM"; else pass "área de preparo (com o estado dos agentes) apagada ao sair"; fi
assert_contains "$log" "restic backup $TMP/home/.cdw-state-upload --tag cdw-state" "copia o estado OpenTofu com a tag cdw-state"
if [[ -e "$TMP/home/.cdw-backup.env" ]]; then flunk "credenciais ficaram na VM"; else pass "credenciais apagadas ao sair"; fi
if [[ -e "$TMP/home/.cdw-state-upload" ]]; then flunk "cópia do estado ficou na VM"; else pass "cópia do estado apagada ao sair"; fi

echo "symlink plantado pelo agente:"

# Um agente comprometido troca ~/.claude por um symlink para o home do operador.
# O tar guarda o link como link e não o segue.
mkdir -p "$TMP/alvo-do-operador"
echo credenciais-do-operador >"$TMP/alvo-do-operador/segredo-do-alvo"
rm -rf "$TMP/agent/.claude"
ln -s "$TMP/alvo-do-operador" "$TMP/agent/.claude"
write_env full
rm -rf "$TMP/agent-copy"
status=0
out="$(run_remote)" || status=$?
assert_status 0 "$status" "termina com sucesso"
agent_listing="$(tar -tvf "$TMP/agent-copy" 2>/dev/null || true)"
assert_contains "$agent_listing" ".claude -> $TMP/alvo-do-operador" "guarda o symlink como symlink"
assert_not_contains "$agent_listing" "segredo-do-alvo" "não segue o symlink para dentro do alvo"

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

echo "script lido do stdin (ssh ... bash -s) com bancos no ar:"

# Reprodução do bug real: pelo ssh o script chega pelo stdin do bash, e o
# "docker compose exec -T" lê o stdin (para repassá-lo ao contêiner). Sem
# "</dev/null", ele engolia o resto do script, o bash saía com 0 e o backup
# parecia concluído sem nunca chamar o restic.
cat >"$TMP/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >>"$CDW_TEST_LOG"
case "$*" in
"--version") echo "Docker version 29.9.1" ;;
"compose ps"*) printf 'postgres\nredis\n' ;;
"compose exec"*)
	cat >/dev/null
	echo dados-do-banco
	;;
"compose cp"*) : >"${@: -1}" ;;
esac
exit 0
STUB
mkdir -p "$TMP/home/compose"
write_env full
status=0
out="$(
	HOME="$TMP/home" PATH="$TMP/bin:$PATH" CDW_TEST_LOG="$TMP/log" CDW_TEST_MANIFEST="$TMP/manifest.json" \
		CDW_AGENT_HOME="$TMP/agent" CDW_TEST_AGENT_COPY="$TMP/agent-copy" \
		bash -s <"$ROOT/scripts/lib/backup-remote.sh" 2>&1
)" || status=$?
assert_status 0 "$status" "termina com sucesso"
assert_contains "$out" "concluído: snapshot" "chega ao fim do script (o stdin não foi engolido)"
log="$(cat "$TMP/log")"
assert_contains "$log" "restic backup $TMP/home/work" "o snapshot é realmente feito"
assert_contains "$log" "restic forget" "aplica a retenção depois do snapshot"
assert_contains "$(jq -c .dumps "$TMP/manifest.json")" "postgres-" "o dump do PostgreSQL entra no manifesto"

finish
