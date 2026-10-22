#!/usr/bin/env bash
# Testa que o apply de um plano salvo roda sem variáveis TF_VAR_* no ambiente
# (o plan.sh exporta o tipo escolhido e o CIDR só no próprio processo; um .env
# com valores diferentes ou vazios fazia o apply recusar o plano).
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

echo "apply do plano salvo sem variáveis no ambiente:"

mkdir -p "$TMP/bin"
cat >"$TMP/bin/tofu" <<'STUB'
#!/usr/bin/env bash
env | grep '^TF_VAR_' >>"$STUB_LOG" || true
echo "$*" >>"$STUB_ARGS"
STUB
chmod +x "$TMP/bin/tofu"
export STUB_LOG="$TMP/vars.log" STUB_ARGS="$TMP/args.log"
: >"$STUB_LOG"
PATH="$TMP/bin:$PATH"

# Situação real: valores do .env diferentes do plano, um deles vazio.
export TF_VAR_server_type=cx43 TF_VAR_admin_cidr="" TF_VAR_location=nbg1 TF_VAR_name=cdw
tf_run apply -input=false plano.tfplan
assert_contains "$(cat "$STUB_LOG")" "TF_VAR_server_type=cx43" "sem a limpeza, o apply enxerga as variáveis do .env"

: >"$STUB_LOG"
cdw_unset_tf_vars
tf_run apply -input=false plano.tfplan
assert_status "" "$(cat "$STUB_LOG")" "depois de cdw_unset_tf_vars, o apply não vê nenhuma TF_VAR_*"
assert_contains "$(tail -n1 "$STUB_ARGS")" "apply -input=false plano.tfplan" "o apply continua usando o plano salvo"

other="$(env | grep -c '^TF_VAR_' || true)"
assert_status "0" "$other" "nenhuma TF_VAR_* sobra no ambiente do script"

up_unset="$(grep -n 'cdw_unset_tf_vars' "$ROOT/scripts/up.sh" | head -n1 | cut -d: -f1)"
up_apply="$(grep -n 'tf_run apply' "$ROOT/scripts/up.sh" | head -n1 | cut -d: -f1)"
if [[ -n "$up_unset" && -n "$up_apply" && "$up_unset" -lt "$up_apply" ]]; then
	pass "up.sh limpa as variáveis antes do apply"
else
	flunk "up.sh precisa chamar cdw_unset_tf_vars antes do apply"
fi

finish
