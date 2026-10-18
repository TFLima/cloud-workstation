#!/usr/bin/env bash
# Verifica o estado deixado por scripts/bootstrap.sh numa máquina Ubuntu 24.04
# (runner do CI ou VM). Precisa de sudo. Uso: check-bootstrap.sh <usuario> <versao>
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

user="${1:?usuário}"
version="${2:?versão}"

echo "bootstrap:"

sshd_cfg="$(sudo sshd -T -C "user=$user,host=localhost,addr=127.0.0.1")"
for kv in "passwordauthentication no" "permitrootlogin no" "kbdinteractiveauthentication no" "authenticationmethods publickey" "allowusers $user" "x11forwarding no"; do
	if grep -qx "$kv" <<<"$sshd_cfg"; then pass "sshd: $kv"; else flunk "sshd: $kv"; fi
done

ufw_status="$(sudo ufw status verbose)"
assert_contains "$ufw_status" "Status: active" "ufw ativo"
assert_contains "$ufw_status" "Default: deny (incoming)" "ufw nega entrada por padrão"
assert_contains "$ufw_status" "22/tcp" "ufw permite SSH"

assert_status "version=$version" "$(cat /etc/cdw/bootstrap-version)" "marcador de versão do bootstrap"
if [[ -d "/home/$user/work" ]]; then pass "diretório ~/work criado"; else flunk "diretório ~/work ausente"; fi
assert_contains "$(cat /etc/apt/apt.conf.d/20auto-upgrades)" 'Unattended-Upgrade "1"' "atualizações automáticas ativas"
if id -nG "$user" | tr ' ' '\n' | grep -qx docker; then pass "$user no grupo docker"; else flunk "$user fora do grupo docker"; fi
for cmd in git jq make restic tmux; do
	if command -v "$cmd" >/dev/null; then pass "pacote $cmd"; else flunk "pacote $cmd ausente"; fi
done

restic_version="${3:-}"
if [[ -n "$restic_version" ]]; then
	assert_status "$restic_version" "$(dpkg-query -W -f='${Version}' restic 2>/dev/null || true)" "restic na versão fixada"
	if apt-mark showhold | grep -qx restic; then pass "restic retido (apt-mark hold)"; else flunk "restic sem apt-mark hold"; fi
fi

home="$(getent passwd "$user" | cut -d: -f6)"
npm_prefix="$home/.local/share/cdw-agents"

if [[ -x "$npm_prefix/bin/claude" ]]; then pass "claude instalado para $user"; else flunk "claude ausente em $npm_prefix/bin"; fi
if [[ -x "$npm_prefix/bin/codex" ]]; then pass "codex instalado para $user"; else flunk "codex ausente em $npm_prefix/bin"; fi
if [[ -L /usr/local/bin/node ]]; then pass "node symlinkado em /usr/local/bin (o codex é um script \"env node\")"; else flunk "node ausente em /usr/local/bin"; fi
# /usr/local/bin (não um rc de shell): precisa funcionar também num comando
# não interativo e não-login via "ssh host comando". Roda de verdade (não só
# "command -v"), porque um "env node" sem node no PATH resolve mas falha ao
# executar.
for agent in claude codex; do
	resolved="$(sudo -u "$user" env -i "PATH=/usr/local/bin:/usr/bin:/bin" sh -c "command -v $agent" 2>/dev/null || true)"
	assert_status "/usr/local/bin/$agent" "$resolved" "$agent resolvido via /usr/local/bin num shell não interativo"
	output="$(sudo -u "$user" env -i "PATH=/usr/local/bin:/usr/bin:/bin" "HOME=$home" sh -c "$agent --version" 2>&1 || true)"
	if [[ "$output" != *"No such file or directory"* && -n "$output" ]]; then
		pass "$agent --version roda num shell não interativo (saída: $output)"
	else
		flunk "$agent --version falhou num shell não interativo: ${output:-<vazio>}"
	fi
done

finish
