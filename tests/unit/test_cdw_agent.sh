#!/usr/bin/env bash
# Testa o lançador cdw-agent embutido em scripts/bootstrap.sh (ADR-0008) com um
# sudo falso: ele precisa trocar para o usuário dos agentes, manter o diretório
# atual, repassar os argumentos sem reinterpretá-los e acertar o PATH.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

render() {
	local user="$1" out="$2"
	sed -n "/<<'LAUNCHER'/,/^LAUNCHER\$/p" "$ROOT/scripts/bootstrap.sh" | sed '1d;$d' |
		sed -e "s|@AGENT_USER@|$user|" -e "s|@AGENT_BIN@|$TMP/agent/bin|" -e "s|@NODE_BIN@|$TMP/node/bin|" >"$out"
	chmod +x "$out"
}

mkdir -p "$TMP/bin" "$TMP/work dir" "$TMP/agent/bin"
cat >"$TMP/bin/sudo" <<'STUB'
#!/usr/bin/env bash
echo "sudo $*" >"$CDW_TEST_SUDO_LOG"
[[ "$1" == "-u" ]] || exit 1
shift 2
[[ "$1" == "-H" ]] && shift
[[ "$1" == "--" ]] && shift
exec "$@"
STUB
cat >"$TMP/agent/bin/fake-agent" <<'STUB'
#!/usr/bin/env bash
printf 'pwd=%s\npath=%s\nargs=%s\n' "$PWD" "$PATH" "$*"
STUB
chmod +x "$TMP/bin/sudo" "$TMP/agent/bin/fake-agent"

echo "cdw-agent:"

render agente-que-nao-sou-eu "$TMP/cdw-agent"
status=0
(cd "$TMP/work dir" && PATH="$TMP/bin:$PATH" "$TMP/cdw-agent") 2>/dev/null || status=$?
assert_status 2 "$status" "sem argumentos, sai com 2"

# O argumento '$HOME;x' é literal de propósito: não pode ser expandido nem executado.
# shellcheck disable=SC2016
out="$(cd "$TMP/work dir" && CDW_TEST_SUDO_LOG="$TMP/sudo.log" PATH="$TMP/bin:$PATH" "$TMP/cdw-agent" fake-agent 'um arg' '$HOME;x')"
assert_contains "$(cat "$TMP/sudo.log")" "-u agente-que-nao-sou-eu -H" "chama sudo -u para o usuário dos agentes"
assert_contains "$out" "pwd=$TMP/work dir" "mantém o diretório atual (mesmo com espaço)"
assert_contains "$out" "args=um arg \$HOME;x" "repassa os argumentos sem reinterpretar"
assert_contains "$out" "path=$TMP/agent/bin:$TMP/node/bin:/usr/local/bin" "usa o PATH dos agentes"

render "$(id -un)" "$TMP/cdw-agent-self"
rm -f "$TMP/sudo.log"
out="$(cd "$TMP/work dir" && CDW_TEST_SUDO_LOG="$TMP/sudo.log" PATH="$TMP/bin:$PATH" "$TMP/cdw-agent-self" fake-agent oi)"
assert_contains "$out" "args=oi" "já como o usuário dos agentes, executa direto"
if [[ -e "$TMP/sudo.log" ]]; then flunk "não deveria chamar sudo quando já é o usuário dos agentes"; else pass "não chama sudo quando já é o usuário dos agentes"; fi

finish
