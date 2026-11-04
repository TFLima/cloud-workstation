#!/usr/bin/env bash
# Testa make push (scripts/push.sh) e scripts/vm-info.sh com tofu/ssh/scp
# falsos: o destino vem do estado (IP atual), a subpasta é validada e a chave
# de host é conferida pelo known_hosts próprio da VM.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/assert.sh
source "$ROOT/tests/lib/assert.sh"
# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state" "$TMP/src/pasta"
cat >"$TMP/bin/tofu" <<'STUB'
#!/usr/bin/env bash
args=("$@")
[[ "${args[0]}" == -chdir=* ]] && args=("${args[@]:1}")
case "${args[0]} ${args[1]:-}" in
"state list") echo hcloud_server.workstation ;;
"output -raw")
	case "${args[2]}" in
	server_id) printf 4242 ;;
	ipv4) printf 203.0.113.77 ;;
	username) printf dev ;;
	esac
	;;
esac
STUB
for tool in ssh scp; do
	# shellcheck disable=SC2016 # $* e $STUB_LOG são do stub, não deste script
	printf '#!/usr/bin/env bash\necho "%s $*" >>"$STUB_LOG"\n' "$tool" >"$TMP/bin/$tool"
done
chmod +x "$TMP/bin/"*
: >"$TMP/state/terraform.tfstate"
printf 'frase-de-teste-com-mais-de-16\n' >"$TMP/pass"
echo "203.0.113.77 ssh-ed25519 AAAAteste" >"$TMP/state/known_hosts.4242"
touch "$TMP/src/a.txt"

export PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/calls.log" CDW_TF_BIN="$TMP/bin/tofu" \
	CDW_STATE_DIR="$TMP/state" CDW_STATE_PASSPHRASE_FILE="$TMP/pass" CDW_ENV_FILE="$TMP/sem.env" \
	CDW_SSH_PUBLIC_KEY_FILE="$TMP/id.pub"

echo "subpasta de destino:"
for ok in "" proj proj/site a.b_c-d; do
	if cdw_valid_work_subdir "$ok"; then pass "aceita '$ok'"; else flunk "recusou '$ok'"; fi
done
for bad in /etc ../fora a/../.. "com espaco" "-rf" "x;rm" "a\$(id)" "\~/x"; do
	if cdw_valid_work_subdir "$bad"; then flunk "aceitou '$bad'"; else pass "recusa '$bad'"; fi
done

echo "vm-info:"
out="$(bash "$ROOT/scripts/vm-info.sh" 2>/dev/null)"
assert_contains "$out" "server_id=4242" "imprime o id da VM"
assert_contains "$out" "ipv4=203.0.113.77" "imprime o IP atual"
assert_contains "$out" "username=dev" "imprime o usuário"
assert_contains "$out" "hostkey=203.0.113.77 ssh-ed25519 AAAAteste" "repassa as chaves de host conhecidas"

echo "push:"
cd "$TMP/src"
: >"$STUB_LOG"
bash "$ROOT/scripts/push.sh" -d proj/site a.txt pasta 2>/dev/null
calls="$(cat "$STUB_LOG")"
assert_contains "$calls" "dev@203.0.113.77 mkdir -p -- '/home/dev/work/proj/site'" "cria a subpasta no IP atual"
assert_contains "$calls" "-r -- a.txt pasta dev@203.0.113.77:/home/dev/work/proj/site/" "copia arquivos e pastas com scp -r"
assert_contains "$calls" "UserKnownHostsFile=$TMP/state/known_hosts.4242" "usa o known_hosts próprio da VM"
assert_contains "$calls" "StrictHostKeyChecking=accept-new" "não desliga a verificação da chave de host"
assert_not_contains "$calls" "StrictHostKeyChecking=no" "nunca usa StrictHostKeyChecking=no"

: >"$STUB_LOG"
bash "$ROOT/scripts/push.sh" a.txt 2>/dev/null
assert_contains "$(cat "$STUB_LOG")" "dev@203.0.113.77:/home/dev/work/" "sem -d, copia para ~/work"

status=0
bash "$ROOT/scripts/push.sh" -d ../fora a.txt 2>/dev/null || status=$?
assert_status 1 "$status" "recusa subpasta com '..'"
status=0
bash "$ROOT/scripts/push.sh" nao-existe.txt 2>/dev/null || status=$?
assert_status 1 "$status" "recusa origem inexistente"
status=0
bash "$ROOT/scripts/push.sh" 2>/dev/null || status=$?
assert_status 2 "$status" "sem argumentos, mostra o uso"

finish
