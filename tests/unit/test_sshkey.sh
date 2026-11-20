#!/usr/bin/env bash
# Testa a chave SSH única (docs/ssh-key.md): impressões digitais, caminho do
# Windows, validação de .pub, chave registrada na Hetzner (API falsa local),
# avisos do preflight, make authorize-key e o bloco do make connect-print.
# Não acessa a rede nem uma VM de verdade (tofu e ssh falsos).
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

TMP="$(mktemp -d)"
mkdir -p "$TMP/fixtures" "$TMP/bin" "$TMP/state" "$TMP/win/.ssh" "$TMP/vmhome"
ssh-keygen -q -t ed25519 -N '' -C wsl -f "$TMP/id_wsl" >/dev/null
ssh-keygen -q -t ed25519 -N '' -C windows -f "$TMP/win/.ssh/id_ed25519" >/dev/null
WSL_MD5="$(ssh-keygen -l -E md5 -f "$TMP/id_wsl.pub" | awk '{print $2}')"
WSL_MD5="${WSL_MD5#MD5:}"
printf '{"ssh_keys":[{"name":"cdw-operator","fingerprint":"%s"}]}\n' "$WSL_MD5" >"$TMP/fixtures/ssh_keys.json"

python3 -I "$ROOT/tests/lib/mock_hcloud.py" "$TMP/fixtures" "$TMP/port" &
MOCK_PID=$!
trap 'kill "$MOCK_PID" 2>/dev/null || true; rm -rf "$TMP"' EXIT
for _ in $(seq 50); do
	if [[ -s "$TMP/port" ]]; then break; fi
	sleep 0.1
done
API="http://127.0.0.1:$(cat "$TMP/port")/v1"

# shellcheck source=scripts/lib/common.sh
source "$ROOT/scripts/lib/common.sh"
# shellcheck source=scripts/lib/hcloud.sh
source "$ROOT/scripts/lib/hcloud.sh"
# shellcheck source=scripts/lib/sshkey.sh
source "$ROOT/scripts/lib/sshkey.sh"

echo "funções da chave:"
assert_status "$WSL_MD5" "$(cdw_key_fp "$TMP/id_wsl.pub" md5)" "MD5 no formato da Hetzner (sem prefixo)"
assert_status "$(ssh-keygen -l -f "$TMP/id_wsl.pub" | awk '{print $2}' | cut -d: -f2-)" "$(cdw_key_fp "$TMP/id_wsl.pub")" "SHA256 sem prefixo"
assert_status "C:/Users/User/.ssh/id_ed25519" "$(cdw_windows_path /mnt/c/Users/User/.ssh/id_ed25519)" "caminho do WSL vira caminho do Windows"
assert_status "" "$(cdw_windows_path /home/user/.ssh/id_ed25519)" "caminho só do WSL não tem equivalente no Windows"
assert_status "$TMP/win/.ssh" "$(CDW_WINDOWS_SSH_DIR="$TMP/win/.ssh/" cdw_windows_ssh_dir)" "CDW_WINDOWS_SSH_DIR fixa a pasta do Windows"

line="$(cdw_pubkey_line "$TMP/id_wsl.pub")"
assert_status "$(cut -d' ' -f1,2 "$TMP/id_wsl.pub")" "$line" "linha da chave sem o comentário"
if cdw_pubkey_line "$TMP/id_wsl" >/dev/null; then flunk "aceitou chave privada"; else pass "recusa chave privada"; fi
cat "$TMP/id_wsl.pub" "$TMP/win/.ssh/id_ed25519.pub" >"$TMP/duas.pub"
if cdw_pubkey_line "$TMP/duas.pub" >/dev/null; then flunk "aceitou duas chaves"; else pass "recusa arquivo com mais de uma chave"; fi
printf "ssh-ed25519 AAAA'; rm -rf ~ #\n" >"$TMP/mal.pub"
if cdw_pubkey_line "$TMP/mal.pub" >/dev/null; then flunk "aceitou linha com aspas"; else pass "recusa linha que poderia escapar das aspas"; fi

HCLOUD_TOKEN="$(printf 'a%.0s' {1..64})" CDW_HCLOUD_API="$API"
HCLOUD_API="$API"
export HCLOUD_TOKEN
assert_status "$WSL_MD5" "$(cdw_hetzner_key_fp)" "lê o fingerprint da chave cdw-operator na Hetzner"
assert_status "" "$(TF_VAR_name=outro cdw_hetzner_key_fp)" "sem chave com o nome do projeto, não imprime nada"

echo "preflight:"
printf 'frase-de-teste-longa\n' >"$TMP/passphrase"
chmod 600 "$TMP/passphrase"
cat >"$TMP/env" <<ENV
HCLOUD_TOKEN=$HCLOUD_TOKEN
TF_VAR_location=nbg1
TF_VAR_server_type=cx43
TF_VAR_admin_cidr=203.0.113.10/32
CDW_SSH_PUBLIC_KEY_FILE=$TMP/win/.ssh/id_ed25519.pub
CDW_STATE_PASSPHRASE_FILE=$TMP/passphrase
ENV
chmod 600 "$TMP/env"
run_preflight() {
	set +e
	OUT="$(env -i PATH="$PATH" HOME="$TMP" CDW_TF_BIN=tofu CDW_ENV_FILE="$TMP/env" \
		CDW_HCLOUD_API="$API" CDW_WINDOWS_SSH_DIR="$TMP/win/.ssh" \
		bash "$ROOT/scripts/preflight.sh" 2>&1)"
	STATUS=$?
	set -e
}
run_preflight
assert_status 0 "$STATUS" "chave diferente na Hetzner é aviso, não falha"
assert_contains "$OUT" "não é a do .env" "avisa que a VM atual foi criada com outra chave"
assert_contains "$OUT" "o Windows (VS Code) usa a mesma chave" "reconhece a chave do Windows igual à do .env"
assert_not_contains "$OUT" "$HCLOUD_TOKEN" "token não aparece na saída"
sed -i "s|^CDW_SSH_PUBLIC_KEY_FILE=.*|CDW_SSH_PUBLIC_KEY_FILE=$TMP/id_wsl.pub|" "$TMP/env"
run_preflight
assert_contains "$OUT" "usa OUTRA chave SSH" "avisa quando o Windows usa outra chave"
assert_contains "$OUT" "registrada na Hetzner é a do .env" "reconhece a chave da Hetzner igual à do .env"

echo "authorize-key:"
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
# ssh falso: roda o comando remoto (último argumento) com HOME na "VM".
cat >"$TMP/bin/ssh" <<'STUB'
#!/usr/bin/env bash
echo "ssh $*" >>"$STUB_LOG"
HOME="$VM_HOME" exec bash -c "${*: -1}"
STUB
chmod +x "$TMP/bin/"*
: >"$TMP/state/terraform.tfstate"
run_cdw() {
	set +e
	OUT="$(env PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/calls.log" VM_HOME="$TMP/vmhome" \
		CDW_TF_BIN="$TMP/bin/tofu" CDW_STATE_DIR="$TMP/state" CDW_STATE_PASSPHRASE_FILE="$TMP/passphrase" \
		CDW_ENV_FILE="$TMP/sem.env" CDW_SSH_PUBLIC_KEY_FILE="$TMP/id_wsl.pub" \
		CDW_WINDOWS_SSH_DIR="$TMP/win/.ssh" "$@" 2>&1)"
	STATUS=$?
	set -e
}
win_line="$(cut -d' ' -f1,2 "$TMP/win/.ssh/id_ed25519.pub")"
run_cdw bash "$ROOT/scripts/authorize-key.sh"
assert_status 0 "$STATUS" "autoriza a chave do Windows por padrão"
assert_contains "$(cat "$TMP/vmhome/.ssh/authorized_keys")" "$win_line" "a linha foi acrescentada ao authorized_keys da VM"
assert_contains "$(cat "$TMP/calls.log")" "-i $TMP/id_wsl" "entra na VM com a chave do .env"
run_cdw bash "$ROOT/scripts/authorize-key.sh"
assert_contains "$OUT" "já estava autorizada" "rodar de novo não duplica"
assert_status 1 "$(grep -cF "$win_line" "$TMP/vmhome/.ssh/authorized_keys")" "a chave aparece uma vez só"
run_cdw bash "$ROOT/scripts/authorize-key.sh" "$TMP/id_wsl"
assert_status 1 "$STATUS" "recusa chave privada"
assert_contains "$OUT" "PRIVADA" "explica que é uma chave privada"
assert_not_contains "$(cat "$TMP/vmhome/.ssh/authorized_keys")" "PRIVATE" "nada da chave privada chega à VM"

echo "key-check:"
touch "$TMP/id_wsl"
chmod 600 "$TMP/id_wsl"
run_cdw env CDW_HCLOUD_API="$API" bash "$ROOT/scripts/key-check.sh"
assert_status 0 "$STATUS" "tudo certo depois do authorize-key"
assert_contains "$OUT" "a chave do Windows também está autorizada" "confere a chave do Windows na VM"
assert_contains "$OUT" "MD5     : $WSL_MD5" "mostra o MD5 para comparar com o console da Hetzner"
: >"$TMP/vmhome/.ssh/authorized_keys"
run_cdw env CDW_HCLOUD_API="$API" bash "$ROOT/scripts/key-check.sh"
assert_status 1 "$STATUS" "falha se a chave do Windows não estiver na VM"
assert_contains "$OUT" "rode: make authorize-key" "diz como corrigir"
assert_not_contains "$OUT" "$HCLOUD_TOKEN" "token não aparece na saída"

echo "connect-print:"
run_cdw bash "$ROOT/scripts/connect.sh" --print
assert_contains "$OUT" "IdentityFile ~/.ssh/id_ed25519" "IdentityFile usa a chave do Windows"
assert_contains "$OUT" "ATENÇÃO: esta chave do Windows não é a do .env" "avisa quando a chave do Windows é outra"
run_cdw env CDW_SSH_PUBLIC_KEY_FILE="$TMP/win/.ssh/id_ed25519.pub" bash "$ROOT/scripts/connect.sh" --print
assert_not_contains "$OUT" "ATENÇÃO" "sem aviso quando é a mesma chave"
run_cdw env CDW_WINDOWS_SSH_DIR="$TMP/nao-existe" bash "$ROOT/scripts/connect.sh" --print
assert_contains "$OUT" "IdentityFile ~/.ssh/id_ed25519" "sem a pasta do Windows, usa ~ (que o Windows expande)"
assert_contains "$OUT" "confira com \"make key-check\"" "e pede para conferir a chave"
run_cdw env CDW_SSH_PRIVATE_KEY_FILE=/mnt/c/Users/User/.ssh/id_ed25519 bash "$ROOT/scripts/connect.sh" --print
assert_contains "$OUT" "IdentityFile C:/Users/User/.ssh/id_ed25519" "chave em /mnt/c vira caminho C:/ no bloco do Windows"
assert_not_contains "$OUT" "IdentityFile $TMP/id_wsl" "nunca põe um caminho do WSL no bloco do Windows"

finish
