#!/usr/bin/env bash
# Testa make win-config (scripts/win-ssh-config.sh) com tofu falso e uma pasta
# .ssh do "Windows" temporária: o Host cdw aponta para o IP atual, mantém as
# outras linhas e os outros hosts, usa o known_hosts próprio da VM e escreve os
# túneis de CDW_LOCAL_FORWARDS. O resultado é validado com "ssh -G".
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state" "$TMP/win"
ssh-keygen -q -t ed25519 -N '' -f "$TMP/win/id_ed25519" >/dev/null
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
chmod +x "$TMP/bin/tofu"
: >"$TMP/state/terraform.tfstate"
printf 'frase-de-teste-com-mais-de-16\n' >"$TMP/pass"
echo "203.0.113.77 ssh-ed25519 AAAAteste" >"$TMP/state/known_hosts.4242"

run_cfg() {
	set +e
	OUT="$(env PATH="$TMP/bin:$PATH" CDW_TF_BIN="$TMP/bin/tofu" CDW_STATE_DIR="$TMP/state" \
		CDW_STATE_PASSPHRASE_FILE="$TMP/pass" CDW_ENV_FILE="$TMP/sem.env" \
		CDW_SSH_PUBLIC_KEY_FILE="$TMP/win/id_ed25519.pub" CDW_WINDOWS_SSH_DIR="$TMP/win" \
		"$@" bash "$ROOT/scripts/win-ssh-config.sh" 2>&1)"
	STATUS=$?
	set -e
}
resolved() { ssh -G -F "$TMP/win/config" "${1:-cdw}" 2>/dev/null; }

echo "win-config sem config:"
run_cfg
assert_status 0 "$STATUS" "cria o config do Windows"
assert_contains "$(cat "$TMP/win/config")" "Host cdw" "bloco Host cdw criado"
assert_contains "$(resolved)" "hostname 203.0.113.77" "ssh -G lê o IP atual"
assert_contains "$(cat "$TMP/win/config")" "UserKnownHostsFile ~/.ssh/known_hosts.cdw.4242" "usa o known_hosts próprio da VM"
assert_contains "$(resolved)" "stricthostkeychecking accept-new" "aceita a chave só na primeira vez"
assert_status "$(cat "$TMP/state/known_hosts.4242")" "$(cat "$TMP/win/known_hosts.cdw.4242")" "copia o known_hosts verificado do WSL"

echo "win-config com config existente (CRLF, outro host, túnel manual):"
printf 'Host github.com\r\n    User git\r\n\r\nHost cdw\r\n    HostName 198.51.100.1\r\n    IdentityFile /home/user/.ssh/id_ed25519\r\n    LocalForward 9000 127.0.0.1:9000\r\n    ForwardAgent no\r\n' >"$TMP/win/config"
run_cfg
assert_status 0 "$STATUS" "atualiza o bloco existente"
cfg="$(cat "$TMP/win/config")"
assert_contains "$(resolved)" "hostname 203.0.113.77" "troca o IP antigo pelo atual"
assert_not_contains "$cfg" "198.51.100.1" "não sobra o IP antigo"
assert_not_contains "$cfg" "/home/user/.ssh" "troca o IdentityFile do WSL"
assert_contains "$cfg" "LocalForward 9000 127.0.0.1:9000" "mantém o túnel manual sem CDW_LOCAL_FORWARDS"
assert_contains "$cfg" "ForwardAgent no" "mantém outras opções do bloco"
assert_contains "$(resolved github.com)" "user git" "não mexe em outros hosts"
assert_status 1 "$(grep -c '^Host cdw$' "$TMP/win/config")" "um único bloco Host cdw"
assert_contains "$(cat "$TMP/win/config.bak-cdw")" "198.51.100.1" "guarda a versão anterior"

run_cfg
assert_contains "$OUT" "nada mudou" "rodar de novo não muda nada"

echo "cabeçalhos em minúsculas (o OpenSSH aceita):"
printf 'host cdw\n    HostName 198.51.100.1\nhost producao\n    HostName 192.0.2.9\n    User deploy\n' >"$TMP/win/config"
run_cfg
assert_contains "$(resolved producao)" "hostname 192.0.2.9" "não apaga o HostName do host seguinte"
assert_contains "$(resolved producao)" "user deploy" "não apaga o User do host seguinte"
assert_contains "$(resolved)" "hostname 203.0.113.77" "atualiza o bloco escrito como 'host cdw'"
assert_status 1 "$(grep -ci '^host cdw$' "$TMP/win/config")" "não duplica o bloco"

echo "chave do .env com nome próprio no Windows:"
run_cfg CDW_SSH_PRIVATE_KEY_FILE=/mnt/c/Users/User/.ssh/workstation
assert_contains "$(cat "$TMP/win/config")" "IdentityFile C:/Users/User/.ssh/workstation" "usa a chave do .env quando ela está no disco do Windows"

echo "túneis por CDW_LOCAL_FORWARDS:"
run_cfg CDW_LOCAL_FORWARDS="8000, 18000:3000"
cfg="$(cat "$TMP/win/config")"
assert_contains "$cfg" "LocalForward 8000 127.0.0.1:8000" "porta simples vira túnel 8000 -> 8000"
assert_contains "$cfg" "LocalForward 18000 127.0.0.1:3000" "local:remota"
assert_not_contains "$cfg" "9000" "a lista do .env substitui os túneis antigos"
assert_contains "$(resolved)" "localforward 8000 [127.0.0.1]:8000" "ssh -G aceita os túneis"
run_cfg CDW_LOCAL_FORWARDS="8000;rm"
assert_status 1 "$STATUS" "recusa CDW_LOCAL_FORWARDS inválido"

finish
