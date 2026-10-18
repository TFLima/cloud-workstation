#!/usr/bin/env bash
# Bootstrap idempotente da VM (Ubuntu 24.04). Executado como root pelo cloud-init
# e seguro para rodar de novo: cada etapa verifica o estado antes de alterar.
#
# Variáveis (de /etc/cdw/bootstrap.env ou do ambiente):
#   CDW_USER                 usuário não-root do operador (obrigatório)
#   CDW_AGENT_USER           usuário dos agentes, sem sudo e sem Docker (padrão: agent)
#   CDW_BOOTSTRAP_VERSION    versão registrada em /etc/cdw/bootstrap-version
#   CDW_SKIP_DOCKER_INSTALL  1 = não instala Docker (usado só no teste de CI)
set -Eeuo pipefail

ENV_FILE="${CDW_BOOTSTRAP_ENV:-/etc/cdw/bootstrap.env}"
if [[ -f "$ENV_FILE" ]]; then
	# shellcheck source=/dev/null
	source "$ENV_FILE"
fi

: "${CDW_USER:?CDW_USER não definido}"
CDW_BOOTSTRAP_VERSION="${CDW_BOOTSTRAP_VERSION:-dev}"
CDW_AGENT_USER="${CDW_AGENT_USER:-agent}"
# Grupo que compartilha ~/work entre o operador e os agentes (ADR-0008).
CDW_WORK_GROUP="work"

# Versões fixadas (repositório oficial download.docker.com, Ubuntu noble).
DOCKER_CE_VERSION="5:29.9.1-1~ubuntu.24.04~noble"
CONTAINERD_VERSION="2.4.2-2~ubuntu.24.04~noble"
COMPOSE_VERSION="5.6.0-1~ubuntu.24.04~noble"
BUILDX_VERSION="0.38.0-1~ubuntu.24.04~noble"
DOCKER_GPG_FINGERPRINT="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"

# Node.js (binário oficial de nodejs.org, não um repositório de terceiros)
# usado só para instalar os agentes via npm; versões conferidas em 18/10/2026.
AGENTS_NODE_VERSION="24.22.0"
AGENTS_NODE_SHA256="cc2f601cee82d9a5a233302fe307abc600727035fd7d2c3a3571755989e95008"
CLAUDE_CODE_VERSION="2.1.302"
CODEX_VERSION="0.163.0"
AGENTS_NODE_DIR="/usr/local/cdw-agents-node"

# restic (Fase 4, ADR-0003): fixado via apt (repositório oficial Ubuntu noble,
# mesmo mecanismo de hold do Docker), não por "apt-get install restic" solto.
RESTIC_VERSION="0.16.4-2ubuntu0.24.04.3"

BASE_PACKAGES=(ca-certificates curl gnupg git jq make openssh-server ufw unattended-upgrades tmux htop unzip acl)

export DEBIAN_FRONTEND=noninteractive
LOG_FILE="${CDW_BOOTSTRAP_LOG:-/var/log/cdw-bootstrap.log}"
exec > >(tee -a "$LOG_FILE") 2>&1

log() { printf '[cdw-bootstrap %s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
trap 'log "FALHOU na linha $LINENO (código $?)"' ERR

[[ "$(id -u)" -eq 0 ]] || {
	echo "execute como root" >&2
	exit 1
}

# Grava $2 em $1 somente se o conteúdo mudou. Retorna 0 se gravou, 1 se já estava igual.
write_if_changed() {
	local path="$1" content="$2" mode="${3:-0644}"
	if [[ -f "$path" ]] && [[ "$(cat "$path")" == "$content" ]]; then
		return 1
	fi
	install -d -m 0755 "$(dirname "$path")"
	printf '%s\n' "$content" >"$path.tmp"
	chmod "$mode" "$path.tmp"
	mv "$path.tmp" "$path"
	return 0
}

apt_install_missing() {
	local missing=() pkg
	for pkg in "$@"; do
		dpkg-query -W -f='${Status}' "${pkg%%=*}" 2>/dev/null | grep -q 'install ok installed' || missing+=("$pkg")
	done
	if ((${#missing[@]} > 0)); then
		log "instalando: ${missing[*]}"
		apt-get install -y --no-install-recommends "${missing[@]}"
	fi
}

step_base_packages() {
	log "pacotes base"
	apt-get update -q
	apt_install_missing "${BASE_PACKAGES[@]}"
}

step_restic() {
	log "restic $RESTIC_VERSION (fixado e retido pelo apt-mark hold)"
	local current
	current="$(dpkg-query -W -f='${Version}' restic 2>/dev/null || true)"
	if [[ "$current" != "$RESTIC_VERSION" ]]; then
		log "instalando restic=$RESTIC_VERSION"
		apt-get install -y --no-install-recommends --allow-downgrades --allow-change-held-packages "restic=$RESTIC_VERSION"
	fi
	# Fora do "if": numa VM de uma Fase anterior, o restic pode já estar na
	# versão certa mas sem hold (instalado solto antes desta Fase); sem isso,
	# unattended-upgrades poderia tirá-lo da versão fixada de qualquer jeito.
	apt-mark hold restic >/dev/null
}

step_docker() {
	if [[ "${CDW_SKIP_DOCKER_INSTALL:-0}" == "1" ]]; then
		log "docker: instalação pulada (CDW_SKIP_DOCKER_INSTALL=1)"
		return 0
	fi
	log "docker: repositório oficial com chave verificada"
	local key=/etc/apt/keyrings/docker.asc tmp fpr
	install -d -m 0755 /etc/apt/keyrings
	if [[ ! -s "$key" ]]; then
		tmp="$(mktemp)"
		curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$tmp"
		fpr="$(gpg --show-keys --with-colons "$tmp" | awk -F: '/^fpr:/{print $10; exit}')"
		if [[ "$fpr" != "$DOCKER_GPG_FINGERPRINT" ]]; then
			rm -f "$tmp"
			log "impressão digital da chave Docker inesperada: $fpr"
			return 1
		fi
		install -m 0644 "$tmp" "$key"
		rm -f "$tmp"
	fi
	local arch codename
	arch="$(dpkg --print-architecture)"
	# shellcheck source=/dev/null
	codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
	if write_if_changed /etc/apt/sources.list.d/docker.sources "Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $codename
Components: stable
Architectures: $arch
Signed-By: $key"; then
		apt-get update -q
	fi

	local want=(
		"docker-ce=$DOCKER_CE_VERSION"
		"docker-ce-cli=$DOCKER_CE_VERSION"
		"containerd.io=$CONTAINERD_VERSION"
		"docker-compose-plugin=$COMPOSE_VERSION"
		"docker-buildx-plugin=$BUILDX_VERSION"
	)
	local spec pkg ver current need=()
	for spec in "${want[@]}"; do
		pkg="${spec%%=*}"
		ver="${spec#*=}"
		current="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)"
		[[ "$current" == "$ver" ]] || need+=("$spec")
	done
	if ((${#need[@]} > 0)); then
		log "instalando ${need[*]}"
		apt-get install -y --no-install-recommends --allow-change-held-packages "${need[@]}"
		apt-mark hold docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin >/dev/null
	fi

	if write_if_changed /etc/docker/daemon.json '{
  "log-driver": "local",
  "log-opts": { "max-size": "20m", "max-file": "3" },
  "live-restore": true
}'; then
		systemctl restart docker
	fi
	systemctl enable --now docker >/dev/null 2>&1 || true
}

step_user() {
	log "usuário $CDW_USER"
	id "$CDW_USER" >/dev/null 2>&1 || {
		log "usuário $CDW_USER não existe (deveria ter sido criado pelo cloud-init)"
		return 1
	}
	if [[ "$CDW_AGENT_USER" == "$CDW_USER" ]]; then
		log "CDW_AGENT_USER não pode ser o usuário do operador ($CDW_USER)"
		return 1
	fi
	if getent group docker >/dev/null && ! id -nG "$CDW_USER" | tr ' ' '\n' | grep -qx docker; then
		usermod -aG docker "$CDW_USER"
	fi

	# Usuário dos agentes (ADR-0008): sem senha, sem sudo, fora do grupo docker
	# e fora do AllowUsers do sshd; só é alcançado por "cdw-agent" a partir do
	# operador. O home é privado: nem o operador lê sem sudo.
	log "usuário dos agentes $CDW_AGENT_USER (sem sudo, sem docker)"
	getent group "$CDW_WORK_GROUP" >/dev/null || groupadd "$CDW_WORK_GROUP"
	id "$CDW_AGENT_USER" >/dev/null 2>&1 ||
		useradd --create-home --shell /bin/bash --user-group \
			--comment "Cloud Dev Workstation agents" "$CDW_AGENT_USER"
	passwd -l "$CDW_AGENT_USER" >/dev/null
	local agent_home
	agent_home="$(getent passwd "$CDW_AGENT_USER" | cut -d: -f6)"
	chmod 0700 "$agent_home"
	local u
	for u in "$CDW_USER" "$CDW_AGENT_USER"; do
		id -nG "$u" | tr ' ' '\n' | grep -qx "$CDW_WORK_GROUP" || usermod -aG "$CDW_WORK_GROUP" "$u"
	done
	# Defesa: um bootstrap antigo ou alteração manual não pode deixar o agente
	# privilegiado.
	local g
	for g in sudo docker; do
		if id -nG "$CDW_AGENT_USER" | tr ' ' '\n' | grep -qx "$g"; then
			gpasswd -d "$CDW_AGENT_USER" "$g" >/dev/null
		fi
	done

	local home work
	home="$(getent passwd "$CDW_USER" | cut -d: -f6)"
	work="$home/work"
	# O agente atravessa o home do operador (x) até ~/work, mas não lista nem lê
	# nada dele; arquivos sensíveis do operador são 0600/0700.
	chmod 0711 "$home"
	install -d -m 2775 -o "$CDW_USER" -g "$CDW_WORK_GROUP" "$work"
	# ACL padrão: arquivos novos em ~/work saem graváveis pelo grupo, qualquer
	# que seja o umask de quem os cria (editor do operador, git do agente).
	setfacl -m "d:g::rwx" "$work" || log "AVISO: sem suporte a ACL em $work; arquivos novos podem ficar só legíveis ao grupo"
}

step_agents() {
	log "Claude Code e Codex CLI (ADR-0004: no host, não na imagem; ADR-0008: como $CDW_AGENT_USER; sem credenciais)"
	local home npm_prefix marker want
	home="$(getent passwd "$CDW_AGENT_USER" | cut -d: -f6)"
	npm_prefix="$home/.local/share/cdw-agents"
	marker="$npm_prefix/versions-installed"
	want="claude-code=$CLAUDE_CODE_VERSION codex=$CODEX_VERSION"

	step_agents_launcher "$npm_prefix"

	if [[ -f "$marker" ]] && [[ "$(cat "$marker")" == "$want" ]]; then
		return 0
	fi

	if [[ ! -x "$AGENTS_NODE_DIR/bin/node" ]]; then
		log "node.js oficial (só para instalar os agentes via npm)"
		local arch node_arch tmp
		arch="$(dpkg --print-architecture)"
		case "$arch" in
		amd64) node_arch=x64 ;;
		arm64) node_arch=arm64 ;;
		*)
			log "arquitetura não suportada para os agentes: $arch"
			return 1
			;;
		esac
		tmp="$(mktemp)"
		curl -fsSL -o "$tmp" "https://nodejs.org/dist/v${AGENTS_NODE_VERSION}/node-v${AGENTS_NODE_VERSION}-linux-${node_arch}.tar.xz"
		if [[ "$node_arch" == "x64" ]]; then
			echo "${AGENTS_NODE_SHA256}  $tmp" | sha256sum -c -
		fi
		install -d -m 0755 "$AGENTS_NODE_DIR"
		tar -xJf "$tmp" -C "$AGENTS_NODE_DIR" --strip-components=1
		rm -f "$tmp"
	fi

	# "install -d -o" só ajusta o dono do último componente; os pais precisam
	# ser do agente, senão o Claude Code não consegue criar ~/.local/state.
	install -d -m 0755 -o "$CDW_AGENT_USER" -g "$CDW_AGENT_USER" \
		"$home/.local" "$home/.local/share" "$npm_prefix"
	log "instalando @anthropic-ai/claude-code@$CLAUDE_CODE_VERSION e @openai/codex@$CODEX_VERSION para $CDW_AGENT_USER"
	# su -l limpa o ambiente; numa VM sem proxy de saída isso não muda nada,
	# mas repassamos um eventual proxy de rede (ex.: redes corporativas) em vez
	# de depender de ele ter sido herdado.
	local proxy_env="" var
	for var in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY; do
		[[ -n "${!var:-}" ]] && proxy_env+="$(printf '%q=%q ' "$var" "${!var}")"
	done
	su - "$CDW_AGENT_USER" -c "env $proxy_env PATH=\"$AGENTS_NODE_DIR/bin:\$PATH\" npm_config_prefix=\"$npm_prefix\" \
		npm install -g --no-fund --no-audit \
		'@anthropic-ai/claude-code@$CLAUDE_CODE_VERSION' '@openai/codex@$CODEX_VERSION'"

	# O codex é um script "#!/usr/bin/env node": sem "node" no PATH ele falha
	# com "node: No such file or directory". O node fica em /usr/local/bin; os
	# agentes em si não: quem os chama é o cdw-agent, que acerta o PATH. Sem
	# symlinks de claude/codex em /usr/local/bin, digitar "claude" como
	# operador falha em vez de rodar com os privilégios dele.
	ln -sf "$AGENTS_NODE_DIR/bin/node" /usr/local/bin/node
	local bin
	for bin in claude codex; do
		if [[ -L "/usr/local/bin/$bin" ]]; then rm -f "/usr/local/bin/$bin"; fi
	done
	printf '%s\n' "$want" >"$marker"
	chown "$CDW_AGENT_USER:$CDW_AGENT_USER" "$marker"
	log "agentes instalados; login (cdw-agent claude / cdw-agent codex) é feito pelo operador via SSH, nunca embutido aqui"
}

# Lançador dos agentes: roda o comando como o usuário dos agentes, no diretório
# atual, com o PATH dos agentes. Chamado pelo operador (que tem sudo); o agente
# em si não tem. Instalado antes do marcador de versões porque não depende dele.
step_agents_launcher() {
	local npm_prefix="$1" launcher
	launcher="$(
		cat <<'LAUNCHER'
#!/usr/bin/env bash
# Roda um comando (claude, codex, bash...) como o usuário dos agentes.
set -Eeuo pipefail
agent_user="@AGENT_USER@"
agent_path="@AGENT_BIN@:@NODE_BIN@:/usr/local/bin:/usr/bin:/bin"
if (($# == 0)); then
	echo "uso: cdw-agent claude|codex|bash [argumentos...]" >&2
	exit 2
fi
if [[ "$(id -un)" == "$agent_user" ]]; then
	exec env "PATH=$agent_path" "$@"
fi
exec sudo -u "$agent_user" -H -- env "PATH=$agent_path" \
	bash -c 'cd "$1" && shift && exec "$@"' cdw-agent "$PWD" "$@"
LAUNCHER
	)"
	launcher="${launcher//@AGENT_USER@/$CDW_AGENT_USER}"
	launcher="${launcher//@AGENT_BIN@/$npm_prefix/bin}"
	launcher="${launcher//@NODE_BIN@/$AGENTS_NODE_DIR/bin}"
	write_if_changed /usr/local/bin/cdw-agent "$launcher" 0755 || true
}

step_ssh() {
	log "sshd: somente chave, sem root"
	local conf=/etc/ssh/sshd_config.d/10-cdw-hardening.conf
	# Arquivos em sshd_config.d são lidos em ordem e o primeiro valor vence,
	# por isso o prefixo 10- se sobrepõe ao 50-cloud-init.conf.
	if write_if_changed "$conf" "PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
AuthenticationMethods publickey
AllowUsers $CDW_USER
X11Forwarding no
AllowAgentForwarding no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 60
ClientAliveCountMax 5"; then
		# Com ssh.socket (padrão no 24.04) o diretório pode não existir antes da
		# primeira conexão, e sem ele `sshd -t` falha.
		install -d -m 0755 /run/sshd
		if sshd -t; then
			systemctl try-reload-or-restart ssh.service || true
		else
			rm -f "$conf"
			log "configuração sshd inválida; arquivo removido"
			return 1
		fi
	fi
}

step_firewall() {
	log "ufw: entrada negada exceto SSH"
	ufw default deny incoming >/dev/null
	ufw default allow outgoing >/dev/null
	# O firewall de nuvem já restringe a origem ao IP do operador. Sem "ufw limit":
	# ele corta um IP que abre 6 conexões em 30 s, e o VS Code Remote - SSH abre
	# várias ao conectar e reconectar. Também sem fixar o CIDR aqui: o IP do
	# operador muda, e o cloud-init não é reaplicado numa VM existente.
	if ufw status | grep -qE '^22/tcp +LIMIT'; then
		ufw delete limit 22/tcp >/dev/null
	fi
	ufw allow 22/tcp comment 'ssh' >/dev/null
	if ! ufw status | grep -q '^Status: active'; then
		ufw --force enable >/dev/null
	fi
}

step_updates() {
	log "atualizações automáticas de segurança"
	write_if_changed /etc/apt/apt.conf.d/20auto-upgrades 'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";' || true
}

step_marker() {
	write_if_changed /etc/cdw/bootstrap-version "version=$CDW_BOOTSTRAP_VERSION" || true
	date -u +%FT%TZ >/etc/cdw/bootstrap-completed-at
}

log "início (versão $CDW_BOOTSTRAP_VERSION)"
step_base_packages
step_restic
step_docker
step_user
step_agents
step_ssh
step_firewall
step_updates
step_marker
log "concluído"
