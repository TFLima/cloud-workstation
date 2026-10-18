#!/usr/bin/env bash
# Asserções mínimas para os testes em Bash (sem dependências externas).

TESTS_FAILED=0

pass() { printf '  ok   %s\n' "$1"; }
flunk() {
	printf '  FAIL %s\n' "$1"
	TESTS_FAILED=$((TESTS_FAILED + 1))
}

assert_status() {
	local expected="$1" actual="$2" name="$3"
	if [[ "$expected" == "$actual" ]]; then pass "$name"; else flunk "$name (esperado $expected, obtido $actual)"; fi
}

assert_contains() {
	local haystack="$1" needle="$2" name="$3"
	if [[ "$haystack" == *"$needle"* ]]; then pass "$name"; else flunk "$name (não contém: $needle)"; fi
}

assert_not_contains() {
	local haystack="$1" needle="$2" name="$3"
	if [[ "$haystack" != *"$needle"* ]]; then pass "$name"; else flunk "$name (contém indevidamente o valor)"; fi
}

finish() {
	if ((TESTS_FAILED > 0)); then
		printf '%d falha(s)\n' "$TESTS_FAILED"
		exit 1
	fi
}
