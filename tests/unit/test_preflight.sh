#!/usr/bin/env bash
# Testa scripts/preflight.sh com arquivos temporários; não acessa a rede.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKE_TOKEN="$(printf 'a%.0s' {1..64})"
ssh-keygen -q -t ed25519 -N '' -f "$TMP/id_test" >/dev/null
printf 'frase-de-teste-longa\n' >"$TMP/passphrase"
chmod 600 "$TMP/passphrase"

write_env() {
	cat >"$TMP/env" <<ENV
HCLOUD_TOKEN=$FAKE_TOKEN
TF_VAR_location=nbg1
TF_VAR_server_type=cx43
TF_VAR_admin_cidr=${1:-203.0.113.10/32}
CDW_SSH_PUBLIC_KEY_FILE=${2:-$TMP/id_test.pub}
CDW_STATE_PASSPHRASE_FILE=$TMP/passphrase
ENV
	chmod 600 "$TMP/env"
}

run_preflight() {
	set +e
	OUT="$(env -i PATH="$PATH" HOME="$TMP" CDW_TF_BIN=tofu CDW_ENV_FILE="$TMP/env" \
		bash "$ROOT/scripts/preflight.sh" 2>&1)"
	STATUS=$?
	set -e
}

echo "preflight:"

write_env
run_preflight
assert_status 0 "$STATUS" "configuração válida passa"
assert_not_contains "$OUT" "$FAKE_TOKEN" "token não aparece na saída"

write_env "0.0.0.0/0"
run_preflight
assert_status 1 "$STATUS" "admin_cidr 0.0.0.0/0 é rejeitado"
assert_contains "$OUT" "não pode ser 0.0.0.0/0" "mensagem explica o CIDR aberto"

write_env "203.0.113.10/32" "$TMP/id_test"
run_preflight
assert_status 1 "$STATUS" "chave privada no lugar da pública é rejeitada"
assert_contains "$OUT" "chave PRIVADA" "mensagem aponta a chave privada"

write_env
chmod 644 "$TMP/env"
run_preflight
assert_status 1 "$STATUS" ".env legível por outros é recusado"
assert_contains "$OUT" "chmod 600" "mensagem sugere chmod 600"

write_env
sed -i 's/^HCLOUD_TOKEN=.*/HCLOUD_TOKEN=curto/' "$TMP/env"
run_preflight
assert_status 1 "$STATUS" "token em formato inválido é rejeitado"
assert_not_contains "$OUT" "curto" "token inválido também não é impresso"

write_env
chmod 644 "$TMP/passphrase"
run_preflight
assert_status 1 "$STATUS" "passphrase do estado com permissão aberta é rejeitada"
chmod 600 "$TMP/passphrase"

write_env
printf 'curta\n' >"$TMP/passphrase"
run_preflight
assert_status 1 "$STATUS" "passphrase do estado com menos de 16 caracteres é rejeitada"
assert_not_contains "$OUT" "curta" "passphrase não aparece na saída"

finish
