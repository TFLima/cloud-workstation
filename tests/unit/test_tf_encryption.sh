#!/usr/bin/env bash
# Testa a montagem do TF_ENCRYPTION sem imprimir a passphrase.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC2016 # expandido pelo bash filho
SNIPPET='source "$ROOT/scripts/lib/common.sh"; source "$ROOT/scripts/lib/tf.sh"; cdw_setup_encryption; printf "%s" "${TF_ENCRYPTION:-}"'

run_setup() {
	set +e
	OUT="$(
		env -i PATH="$PATH" HOME="$TMP" CDW_TF_BIN="$1" CDW_STATE_PASSPHRASE_FILE="$TMP/pass" \
			CDW_ALLOW_UNENCRYPTED_STATE="${2:-0}" ROOT="$ROOT" bash -c "$SNIPPET" 2>&1
	)"
	STATUS=$?
	set -e
}

echo "criptografia do estado:"

printf '%s\n' 'frase "longa" com \ barra 123' >"$TMP/pass"
run_setup tofu
assert_status 0 "$STATUS" "passphrase válida gera configuração"
assert_contains "$OUT" 'passphrase = "frase \"longa\" com \\ barra 123"' "aspas e barras escapadas"
assert_contains "$OUT" 'enforced = true' "criptografia obrigatória no estado e no plano"

printf 'curta\n' >"$TMP/pass"
run_setup tofu
assert_status 1 "$STATUS" "passphrase curta é recusada"
assert_not_contains "$OUT" "curta" "passphrase curta não é impressa"

printf 'uma-frase-bem-longa-aqui\n' >"$TMP/pass"
run_setup terraform
assert_status 1 "$STATUS" "Terraform sem permissão explícita é recusado (estado ficaria aberto)"

run_setup terraform 1
assert_status 0 "$STATUS" "Terraform aceito com CDW_ALLOW_UNENCRYPTED_STATE=1"
assert_contains "$OUT" "SEM criptografia" "aviso claro de estado sem criptografia"

finish
