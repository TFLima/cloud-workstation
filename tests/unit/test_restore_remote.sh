#!/usr/bin/env bash
# Testa scripts/lib/restore-remote.sh com restic e sudo falsos: o estado dos
# agentes é extraído COMO o usuário dos agentes (ADR-0008), nunca como o
# operador, e ~/work volta com o grupo compartilhado mesmo vindo de um snapshot
# de antes do ADR-0008 (0755, grupo do operador).
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"
mkdir -p "$TMP/bin" "$HOME_DIR" "$TMP/agent" "$TMP/agent-fonte/.claude" "$TMP/snapshot"

# Conteúdo do "snapshot": ~/work do operador (0755, como num snapshot antigo) e a
# área de preparo com o estado dos agentes, no formato que backup-remote.sh produz.
snap_home="$TMP/snapshot$HOME_DIR"
mkdir -p "$snap_home/work/projeto" "$snap_home/.cdw-backup-stage.ABC"
chmod 0755 "$snap_home/work" "$snap_home/work/projeto"
echo codigo >"$snap_home/work/projeto/app.txt"
chmod 0644 "$snap_home/work/projeto/app.txt"
echo '{"token":"falso"}' >"$TMP/agent-fonte/.claude/.credentials.json"
chmod 0600 "$TMP/agent-fonte/.claude/.credentials.json"
tar -C "$TMP/agent-fonte" -cf "$snap_home/.cdw-backup-stage.ABC/agent-home.tar" .claude
echo '{"bootstrap_version":"version=4","dumps":[]}' >"$snap_home/.cdw-backup-stage.ABC/manifest.json"

cat >"$TMP/bin/restic" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "restore" ]]; then
	while (($#)); do
		[[ "$1" == "--target" ]] && target="$2"
		shift
	done
	cp -a "$CDW_TEST_SNAPSHOT/." "$target/"
fi
exit 0
STUB
# sudo falso: registra o usuário pedido (-u), ignora as opções e executa o
# comando; o teste não troca de usuário de verdade.
cat >"$TMP/bin/sudo" <<'STUB'
#!/usr/bin/env bash
while [[ "${1:-}" == -* ]]; do
	if [[ "$1" == "-u" ]]; then echo "sudo -u $2 ${*:3}" >>"$CDW_TEST_LOG"; shift 2; else shift; fi
done
exec "$@"
STUB
chmod +x "$TMP/bin/restic" "$TMP/bin/sudo"

echo "restore com estado dos agentes:"

printf 'RESTIC_REPOSITORY=/tmp/repo-falso\nRESTIC_PASSWORD=teste\n' >"$HOME_DIR/.cdw-backup.env"
: >"$TMP/log"
status=0
output="$(HOME="$HOME_DIR" PATH="$TMP/bin:$PATH" CDW_TEST_SNAPSHOT="$TMP/snapshot" CDW_TEST_LOG="$TMP/log" \
	CDW_AGENT_USER=agent CDW_AGENT_HOME="$TMP/agent" CDW_WORK_GROUP="$(id -gn)" \
	bash "$ROOT/scripts/lib/restore-remote.sh" 2>&1)" || status=$?
assert_status 0 "$status" "termina com sucesso"
assert_contains "$output" "extraído como agent" "avisa que extraiu o estado dos agentes"
assert_contains "$(cat "$TMP/log")" "sudo -u agent tar -xpf" "extrai o estado dos agentes COMO o usuário dos agentes"
if [[ -f "$TMP/agent/.claude/.credentials.json" ]]; then pass "o .claude volta para o home do usuário dos agentes"; else flunk "o .claude não voltou para o home dos agentes"; fi
assert_status "600" "$(stat -c '%a' "$TMP/agent/.claude/.credentials.json" 2>/dev/null || true)" "credenciais restauradas com modo 0600"
if [[ -e "$HOME_DIR/.claude" ]]; then flunk "estado dos agentes foi parar no home do operador"; else pass "nada do estado dos agentes no home do operador"; fi

echo "restore de ~/work vindo de um snapshot antigo:"
if [[ -f "$HOME_DIR/work/projeto/app.txt" ]]; then pass "o work volta para o home do operador"; else flunk "o work não foi restaurado"; fi
assert_status "2775" "$(stat -c '%a' "$HOME_DIR/work")" "a pasta work volta com setgid e escrita para o grupo"
assert_status "2775" "$(stat -c '%a' "$HOME_DIR/work/projeto")" "subdiretório volta com setgid e escrita para o grupo"
assert_status "664" "$(stat -c '%a' "$HOME_DIR/work/projeto/app.txt")" "arquivo volta gravável pelo grupo"
if [[ -e "$HOME_DIR/.cdw-backup.env" ]]; then flunk "credenciais ficaram na VM"; else pass "credenciais apagadas ao sair"; fi

finish
