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

home="$(getent passwd "$user" | cut -d: -f6)"
npm_prefix="$home/.local/share/cdw-agents"

if [[ -x "$npm_prefix/bin/claude" ]]; then pass "claude instalado para $user"; else flunk "claude ausente em $npm_prefix/bin"; fi
if [[ -x "$npm_prefix/bin/codex" ]]; then pass "codex instalado para $user"; else flunk "codex ausente em $npm_prefix/bin"; fi
# /usr/local/bin (não um rc de shell): precisa funcionar também num comando
# não interativo e não-login via "ssh host comando".
for agent in claude codex; do
	resolved="$(sudo -u "$user" env -i "PATH=/usr/local/bin:/usr/bin:/bin" sh -c "command -v $agent" 2>/dev/null || true)"
	assert_status "/usr/local/bin/$agent" "$resolved" "$agent resolvido via /usr/local/bin num shell não interativo"
done

finish
