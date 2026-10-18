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
if grep -qE '^22/tcp +ALLOW IN' <<<"$ufw_status"; then pass "ufw: SSH em ALLOW"; else flunk "ufw: SSH não está em ALLOW"; fi
assert_not_contains "$ufw_status" "LIMIT" "ufw sem limite de taxa no SSH (cortaria o VS Code)"

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
agent="${CDW_AGENT_USER:-agent}"

echo "isolamento dos agentes (ADR-0008):"
if id "$agent" >/dev/null 2>&1; then pass "usuário $agent existe"; else flunk "usuário $agent ausente"; fi
agent_home="$(getent passwd "$agent" | cut -d: -f6)"
agent_groups="$(id -nG "$agent")"
if tr ' ' '\n' <<<"$agent_groups" | grep -qxE 'sudo|docker'; then flunk "$agent em grupo privilegiado ($agent_groups)"; else pass "$agent fora dos grupos sudo e docker"; fi
if sudo -u "$agent" sudo -n true >/dev/null 2>&1; then flunk "$agent consegue usar sudo"; else pass "$agent não consegue usar sudo"; fi
if sudo -u "$agent" docker info >/dev/null 2>&1; then flunk "$agent acessa o daemon do Docker"; else pass "$agent não acessa o daemon do Docker"; fi
assert_status "700" "$(stat -c '%a' "$agent_home")" "home de $agent é privado (0700)"
assert_status "711" "$(stat -c '%a' "$home")" "home de $user só atravessável (0711)"
# Caminhos absolutos: este script roda como o usuário do CI, e o sudo pode
# manter o HOME dele em vez do HOME do usuário de destino.
sudo -u "$user" sh -c "umask 077 && echo segredo > '$home/segredo-teste'"
if sudo -u "$agent" cat "$home/segredo-teste" >/dev/null 2>&1; then
	flunk "$agent lê arquivo 0600 de $user"
	sudo ls -ln "$home/segredo-teste" || true
	sudo -u "$agent" id || true
else
	pass "$agent não lê arquivo 0600 de $user"
fi
if sudo -u "$agent" ls "$home" >/dev/null 2>&1; then flunk "$agent lista o home de $user"; else pass "$agent não lista o home de $user"; fi
sudo -u "$user" rm -f "$home/segredo-teste"
if sudo -u "$user" ls "$agent_home" >/dev/null 2>&1; then flunk "$user lista o home de $agent sem sudo"; else pass "$user não lista o home de $agent sem sudo"; fi

# ~/work é compartilhado: cada um grava e o outro continua editando.
sudo -u "$user" sh -c "echo do-operador > '$home/work/do-operador.txt'"
sudo -u "$agent" sh -c "echo do-agente > '$home/work/do-agente.txt'" || true
if sudo -u "$agent" sh -c "echo mais >> '$home/work/do-operador.txt'" 2>/dev/null; then pass "$agent edita arquivo criado por $user em ~/work"; else flunk "$agent não edita arquivo criado por $user em ~/work"; fi
if sudo -u "$user" sh -c "echo mais >> '$home/work/do-agente.txt'" 2>/dev/null; then pass "$user edita arquivo criado por $agent em ~/work"; else flunk "$user não edita arquivo criado por $agent em ~/work"; fi
sudo -u "$user" rm -f "$home/work/do-operador.txt" "$home/work/do-agente.txt"

if ((TESTS_FAILED > 0)); then
	echo "diagnóstico do isolamento:"
	sudo -u "$agent" id || true
	sudo -u "$agent" sh -c 'echo "HOME do agente sob sudo: $HOME"' || true
	sudo -u "$user" sh -c 'echo "HOME do operador sob sudo: $HOME"' || true
	sudo ls -ld "$home" "$home/work" "$agent_home" || true
	sudo ls -la "$home" || true
	sudo getfacl -p "$home/work" || true
fi

echo "agentes instalados:"
npm_prefix="$agent_home/.local/share/cdw-agents"
assert_status "$agent" "$(sudo stat -c '%U' "$agent_home/.local")" "o diretório .local de $agent pertence a $agent"
if sudo test -x "$npm_prefix/bin/claude"; then pass "claude instalado para $agent"; else flunk "claude ausente em $npm_prefix/bin"; fi
if sudo test -x "$npm_prefix/bin/codex"; then pass "codex instalado para $agent"; else flunk "codex ausente em $npm_prefix/bin"; fi
if [[ -L /usr/local/bin/node ]]; then pass "node symlinkado em /usr/local/bin (o codex é um script \"env node\")"; else flunk "node ausente em /usr/local/bin"; fi
if [[ -x /usr/local/bin/cdw-agent ]]; then pass "cdw-agent instalado"; else flunk "cdw-agent ausente"; fi

# O operador chama os agentes pelo cdw-agent, num comando não interativo e
# não-login ("ssh host comando"), e roda de verdade (não só "command -v"):
# um "env node" sem node no PATH resolve mas falha ao executar.
op_env=(env -i "PATH=/usr/local/bin:/usr/bin:/bin" "HOME=$home")
# O diretório atual do CI (o checkout) não é acessível ao operador nem ao
# agente; como numa sessão SSH, o comando começa no home do operador.
assert_status "$agent" "$(sudo -u "$user" "${op_env[@]}" sh -c 'cd ~/work && cdw-agent id -un' 2>/dev/null || true)" "cdw-agent roda o comando como $agent"
assert_status "$home/work" "$(sudo -u "$user" "${op_env[@]}" sh -c 'cd ~/work && cdw-agent pwd' 2>/dev/null || true)" "cdw-agent mantém o diretório atual"
for bin in claude codex; do
	if sudo -u "$user" "${op_env[@]}" sh -c "command -v $bin" >/dev/null 2>&1; then
		flunk "$bin resolve direto para $user (deveria exigir cdw-agent)"
	else
		pass "$bin não resolve direto para $user"
	fi
	output="$(sudo -u "$user" "${op_env[@]}" sh -c "cd ~/work && cdw-agent $bin --version" 2>&1 || true)"
	if [[ "$output" != *"No such file or directory"* && -n "$output" ]]; then
		pass "cdw-agent $bin --version roda num shell não interativo (saída: $output)"
	else
		flunk "cdw-agent $bin --version falhou num shell não interativo: ${output:-<vazio>}"
	fi
done

finish
