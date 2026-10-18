#!/usr/bin/env bash
# Testa a escolha do tipo de servidor contra uma API Hetzner falsa e local.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

TMP="$(mktemp -d)"
python3 -I "$ROOT/tests/lib/mock_hcloud.py" "$ROOT/tests/fixtures/hcloud" "$TMP/port" &
MOCK_PID=$!
trap 'kill "$MOCK_PID" 2>/dev/null || true; rm -rf "$TMP"' EXIT
for _ in $(seq 50); do
	if [[ -s "$TMP/port" ]]; then break; fi
	sleep 0.1
done

CDW_HCLOUD_API="http://127.0.0.1:$(cat "$TMP/port")/v1"
export CDW_HCLOUD_API
export HCLOUD_TOKEN
HCLOUD_TOKEN="$(printf 'a%.0s' {1..64})"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/hcloud.sh
source "$ROOT/scripts/lib/hcloud.sh"

echo "hcloud:"

assert_status "ok 0.1114 69.49" "$(hcloud_check_type cpx42 nbg1)" "cpx42 disponível em nbg1 com preço"
assert_status "indisponivel sem-estoque" "$(hcloud_check_type cx43 nbg1)" "cx43 sem estoque em nbg1"
assert_status "indisponivel nao-x86" "$(hcloud_check_type cax31 nbg1)" "ARM é rejeitado"
assert_status "indisponivel tipo-inexistente" "$(hcloud_check_type zz99 nbg1)" "tipo inexistente"
assert_status "indisponivel nao-oferecido-em-hel1" "$(hcloud_check_type cpx42 hel1)" "localização não oferecida"

assert_status "cpx42 0.1114 69.49" "$(hcloud_select_type nbg1 cx43 cpx42,ccx23 2>/dev/null)" "fallback escolhe cpx42 quando cx43 está sem estoque"
assert_status "cx43 0.0256 15.99" "$(hcloud_select_type fsn1 cx43 cpx42 2>/dev/null)" "cx43 escolhido quando disponível"

set +e
hcloud_select_type nbg1 cx43 cax31 >/dev/null 2>&1
status=$?
set -e
assert_status 1 "$status" "falha quando nenhuma opção está disponível"

assert_status "0.5000" "$(hcloud_ipv4_monthly nbg1)" "preço do IPv4 lido de /pricing"

HCLOUD_TOKEN="$(printf 'a%.0s' {1..64})"
assert_status "$(printf 'firewalls 222 cdw-fw\nservers 111 cdw')" "$(hcloud_list_labeled | sort)" "auditoria lista recursos rotulados (volumes/ssh_keys/images/primary_ips vazios)"

assert_status "9" "$(hcloud_elapsed_hours 2026-10-18T00:00:00Z 2026-10-18T08:30:00Z)" "horas decorridas arredondam para cima (8h30 -> 9h)"
assert_status "8" "$(hcloud_elapsed_hours 2026-10-18T00:00:00Z 2026-10-18T08:00:00Z)" "horas decorridas exatas não arredondam (8h -> 8h)"

HCLOUD_TOKEN="$(printf 'b%.0s' {1..64})"
assert_status "indisponivel erro-na-api" "$(hcloud_check_type cpx42 nbg1 2>/dev/null)" "token recusado vira erro claro"

finish
