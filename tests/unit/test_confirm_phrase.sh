#!/usr/bin/env bash
# Testa cdw_confirm_phrase (make up/down/destroy-vm/restore): errar a frase
# pergunta de novo em vez de cancelar; só o fim da entrada cancela.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

ask() { # <entrada> [CDW_CONFIRM]
	printf '%b' "$1" | CDW_ROOT="$ROOT" CDW_CONFIRM="${2:-}" bash -c \
		'source "$CDW_ROOT/scripts/lib/common.sh"; cdw_confirm_phrase "destruir cdw" "cancelado"; echo CONFIRMADO' 2>&1
}

echo "frase de confirmação:"

status=0
out="$(ask 'destruir cdw\n')" || status=$?
assert_status 0 "$status" "frase certa confirma"
assert_contains "$out" "CONFIRMADO" "segue adiante"

status=0
out="$(ask 'errado\ndestruir  cdw\ndestruir cdw\n')" || status=$?
assert_status 0 "$status" "erra duas vezes e acerta na terceira"
assert_contains "$out" "frase incorreta" "avisa que a frase está incorreta"
assert_contains "$out" "CONFIRMADO" "confirma depois de acertar"

status=0
out="$(ask 'errado\n')" || status=$?
assert_status 1 "$status" "fim da entrada depois de errar cancela (sem laço infinito)"
assert_not_contains "$out" "CONFIRMADO" "não segue adiante"

status=0
out="$(ask '' 'destruir cdw')" || status=$?
assert_status 0 "$status" "CDW_CONFIRM certo dispensa a pergunta"

status=0
out="$(ask '' 'outra coisa')" || status=$?
assert_status 1 "$status" "CDW_CONFIRM errado sem entrada cancela"

finish
