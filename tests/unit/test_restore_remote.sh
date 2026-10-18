#!/usr/bin/env bash
# Testa scripts/lib/restore-remote.sh com restic e sudo falsos: o estado dos
# agentes volta para o home do usuário dos agentes (ADR-0008), com o dono dele,
# e ~/work volta para o home do operador.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"
mkdir -p "$TMP/bin" "$HOME_DIR" "$TMP/agent" "$TMP/snapshot"

# Conteúdo do "snapshot": ~/work do operador e a área de preparo com o estado
# dos agentes, no mesmo layout que o backup-remote.sh produz.
snap_home="$TMP/snapshot$HOME_DIR"
mkdir -p "$snap_home/work/projeto" "$snap_home/.cdw-backup-stage.ABC/agent-home/.claude"
echo codigo >"$snap_home/work/projeto/app.txt"
echo '{"token":"falso"}' >"$snap_home/.cdw-backup-stage.ABC/agent-home/.claude/.credentials.json"
echo '{"bootstrap_version":"version=5","dumps":[]}' >"$snap_home/.cdw-backup-stage.ABC/manifest.json"

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
cat >"$TMP/bin/sudo" <<'STUB'
#!/usr/bin/env bash
echo "sudo $*" >>"$CDW_TEST_LOG"
[[ "${1:-}" == "-n" ]] && shift
# chown para outro usuário não é possível sem root; o teste só registra a chamada.
[[ "$1" == "chown" || "$1" == "install" ]] && {
	[[ "$1" == "install" ]] && { shift; args=(); while (($#)); do case "$1" in -o | -g) shift 2 ;; *) args+=("$1"); shift ;; esac; done; exec install "${args[@]}"; }
	exit 0
}
exec "$@"
STUB
chmod +x "$TMP/bin/restic" "$TMP/bin/sudo"

echo "restore com estado dos agentes:"

printf 'RESTIC_REPOSITORY=/tmp/repo-falso\nRESTIC_PASSWORD=teste\n' >"$HOME_DIR/.cdw-backup.env"
: >"$TMP/log"
status=0
output="$(HOME="$HOME_DIR" PATH="$TMP/bin:$PATH" CDW_TEST_SNAPSHOT="$TMP/snapshot" CDW_TEST_LOG="$TMP/log" \
	CDW_AGENT_USER=agent CDW_AGENT_HOME="$TMP/agent" bash "$ROOT/scripts/lib/restore-remote.sh" 2>&1)" || status=$?
assert_status 0 "$status" "termina com sucesso"
assert_contains "$output" "restaurando $TMP/agent/.claude" "avisa que restaurou o estado dos agentes"
if [[ -f "$TMP/agent/.claude/.credentials.json" ]]; then pass "o .claude volta para o home do usuário dos agentes"; else flunk "o .claude não voltou para o home dos agentes"; fi
if [[ -e "$HOME_DIR/.claude" ]]; then flunk "estado dos agentes foi parar no home do operador"; else pass "nada do estado dos agentes no home do operador"; fi
assert_status "0700" "0$(stat -c '%a' "$TMP/agent/.claude")" "o .claude do agente é restaurado com modo 0700"
assert_contains "$(cat "$TMP/log")" "chown -R agent:agent $TMP/agent/.claude" "ajusta o dono para o usuário dos agentes"
if [[ -f "$HOME_DIR/work/projeto/app.txt" ]]; then pass "o work volta para o home do operador"; else flunk "o work não foi restaurado"; fi
if [[ -e "$HOME_DIR/.cdw-backup.env" ]]; then flunk "credenciais ficaram na VM"; else pass "credenciais apagadas ao sair"; fi

finish
