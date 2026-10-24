#!/usr/bin/env bash
# Testa cdw_ssh_script e cdw_remote_must_finish: um script remoto cujo comando
# lê o stdin não pode truncar o restante do script, e uma saída sem a linha
# final esperada não conta como concluída.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/assert.sh
source "$ROOT/tests/lib/assert.sh"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/tf.sh
source "$ROOT/scripts/lib/tf.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ssh falso: executa localmente o comando remoto (último argumento), mantendo o
# stdin, como o ssh real faz.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/ssh" <<'STUB'
#!/usr/bin/env bash
cmd="${*: -1}"
exec bash -c "$cmd"
STUB
chmod +x "$TMP/bin/ssh"
PATH="$TMP/bin:$PATH"
CDW_STATE_DIR="$TMP/state"
CDW_SSH_PRIVATE_KEY_FILE="$TMP/chave"

echo "script remoto que lê o stdin:"

cat >"$TMP/engole.sh" <<'SCRIPT'
cat >/dev/null
echo "linha-depois-do-cat"
echo "snapshot=${CDW_RESTORE_SNAPSHOT:-nenhum}"
SCRIPT
out="$(cdw_ssh_script srv dev@ip "$TMP/engole.sh" CDW_RESTORE_SNAPSHOT=abc123)"
assert_contains "$out" "linha-depois-do-cat" "o comando que lê o stdin não engole o resto do script"
assert_contains "$out" "snapshot=abc123" "variáveis de ambiente chegam ao script"

printf 'echo antes\nexit 3\n' >"$TMP/falha.sh"
status=0
cdw_ssh_script srv dev@ip "$TMP/falha.sh" >/dev/null || status=$?
assert_status 3 "$status" "propaga o código de saída do script"

echo "linha final obrigatória:"

printf 'echo "[backup] concluído: snapshot x"\n' >"$TMP/ok.sh"
status=0
out="$(cdw_remote_must_finish "[backup] concluído" cdw_ssh_script srv dev@ip "$TMP/ok.sh" 2>&1)" || status=$?
assert_status 0 "$status" "com a linha final, conta como concluído"
assert_contains "$out" "[backup] concluído: snapshot x" "mostra a saída do script"

printf 'echo "[backup] enviando snapshot"\nexit 0\n' >"$TMP/cedo.sh"
status=0
out="$( (cdw_remote_must_finish "[backup] concluído" cdw_ssh_script srv dev@ip "$TMP/cedo.sh") 2>&1)" || status=$?
if ((status != 0)); then pass "sem a linha final, falha mesmo com saída 0"; else flunk "script que saiu cedo foi aceito como concluído"; fi
assert_contains "$out" "NÃO concluído" "explica que o resultado não vale"

status=0
(cdw_remote_must_finish "[backup] concluído" cdw_ssh_script srv dev@ip "$TMP/falha.sh") >/dev/null 2>&1 || status=$?
assert_status 3 "$status" "propaga o código de saída quando o script falha"

finish
