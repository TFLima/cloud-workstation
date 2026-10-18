#!/usr/bin/env bash
# Bootstrap idempotente da VM (Ubuntu 24.04). Executado como root pelo cloud-init
# e seguro para rodar de novo: cada etapa verifica o estado antes de alterar.
#
# Variáveis (de /etc/cdw/bootstrap.env ou do ambiente):
#   CDW_USER                 usuário não-root (obrigatório)
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

# Versões fixadas (repositório oficial download.docker.com, Ubuntu noble).
DOCKER_CE_VERSION="5:29.9.1-1~ubuntu.24.04~noble"
CONTAINERD_VERSION="2.4.2-2~ubuntu.24.04~noble"
COMPOSE_VERSION="5.6.0-1~ubuntu.24.04~noble"
BUILDX_VERSION="0.38.0-1~ubuntu.24.04~noble"
DOCKER_GPG_FINGERPRINT="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"

BASE_PACKAGES=(ca-certificates curl gnupg git jq make openssh-server ufw unattended-upgrades restic tmux htop unzip)

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
	if getent group docker >/dev/null && ! id -nG "$CDW_USER" | tr ' ' '\n' | grep -qx docker; then
		usermod -aG docker "$CDW_USER"
	fi
	local home
	home="$(getent passwd "$CDW_USER" | cut -d: -f6)"
	install -d -m 0755 -o "$CDW_USER" -g "$CDW_USER" "$home/work"
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
	# O firewall de nuvem restringe a origem ao IP do operador; aqui limitamos taxa.
	ufw limit 22/tcp comment 'ssh' >/dev/null
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
step_docker
step_user
step_ssh
step_firewall
step_updates
step_marker
log "concluído"
