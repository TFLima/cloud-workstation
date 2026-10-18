#!/usr/bin/env bash
# Configuração do OpenTofu/Terraform, do estado criptografado e do acesso SSH.
# Requer scripts/lib/common.sh carregado antes.

TF_DIR="$CDW_ROOT/infrastructure/terraform"

cdw_load_config() {
	umask 077
	load_env_file "${CDW_ENV_FILE:-$CDW_ROOT/.env}"
	export TF_VAR_name="${TF_VAR_name:-cdw}"
	CDW_STATE_DIR="$(expand_path "${CDW_STATE_DIR:-~/.local/state/cdw}")"
	export CDW_STATE_DIR
	install -d -m 0700 "$CDW_STATE_DIR"
	CDW_SSH_PUBLIC_KEY_FILE="$(expand_path "${CDW_SSH_PUBLIC_KEY_FILE:-~/.ssh/id_ed25519.pub}")"
	CDW_SSH_PRIVATE_KEY_FILE="$(expand_path "${CDW_SSH_PRIVATE_KEY_FILE:-${CDW_SSH_PUBLIC_KEY_FILE%.pub}}")"
	export CDW_SSH_PUBLIC_KEY_FILE CDW_SSH_PRIVATE_KEY_FILE
}

# Exporta a chave pública e o CIDR do operador para o OpenTofu.
cdw_export_tf_vars() {
	[[ -f "$CDW_SSH_PUBLIC_KEY_FILE" ]] || die "chave pública não encontrada: $CDW_SSH_PUBLIC_KEY_FILE"
	TF_VAR_ssh_public_key="$(cat "$CDW_SSH_PUBLIC_KEY_FILE")"
	export TF_VAR_ssh_public_key
	if [[ -z "${TF_VAR_admin_cidr:-}" ]]; then
		local ip
		ip="$(curl -fsS --max-time 10 "${CDW_IP_ECHO_URL:-https://api.ipify.org}" || true)"
		[[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "não foi possível detectar seu IP público; defina TF_VAR_admin_cidr"
		export TF_VAR_admin_cidr="$ip/32"
		log "SSH será liberado só para o IP detectado $TF_VAR_admin_cidr"
	fi
}

# Monta TF_ENCRYPTION (OpenTofu) a partir do arquivo de passphrase, sem imprimi-la.
cdw_setup_encryption() {
	local tf pass_file pass
	tf="$(tf_bin)" || die "nem tofu nem terraform encontrados"
	if [[ "$tf" != *tofu* ]]; then
		[[ "${CDW_ALLOW_UNENCRYPTED_STATE:-0}" == "1" ]] ||
			die "o estado só é criptografado com OpenTofu; instale tofu ou defina CDW_ALLOW_UNENCRYPTED_STATE=1"
		warn "usando $tf: o estado ficará SEM criptografia em $CDW_STATE_DIR"
		return 0
	fi
	pass_file="$(expand_path "${CDW_STATE_PASSPHRASE_FILE:-~/.config/cdw/state-passphrase}")"
	[[ -f "$pass_file" ]] || die "passphrase do estado não encontrada (CDW_STATE_PASSPHRASE_FILE)"
	pass="$(head -n1 "$pass_file")"
	((${#pass} >= 16)) || die "a passphrase do estado precisa ter pelo menos 16 caracteres"
	pass="${pass//\\/\\\\}"
	pass="${pass//\"/\\\"}"
	TF_ENCRYPTION="$(
		cat <<HCL
key_provider "pbkdf2" "cdw" {
  passphrase = "$pass"
}
method "aes_gcm" "cdw" {
  keys = key_provider.pbkdf2.cdw
}
state {
  method   = method.aes_gcm.cdw
  enforced = true
}
plan {
  method   = method.aes_gcm.cdw
  enforced = true
}
HCL
	)"
	export TF_ENCRYPTION
}

tf_run() {
	local tf
	tf="$(tf_bin)" || die "nem tofu nem terraform encontrados"
	"$tf" -chdir="$TF_DIR" "$@"
}

tf_init() {
	tf_run init -input=false -upgrade=false \
		-backend-config="path=$CDW_STATE_DIR/terraform.tfstate" >/dev/null
}

# Retorna 0 se existe um servidor no estado.
tf_has_server() {
	[[ -f "$CDW_STATE_DIR/terraform.tfstate" ]] || return 1
	tf_run state list 2>/dev/null | grep -qx 'hcloud_server.workstation'
}

tf_output() { tf_run output -raw "$1"; }

# Opções SSH: known_hosts próprio por servidor (aceita a chave na primeira conexão).
cdw_ssh_opts() {
	local server_id="$1"
	local opts=(
		-o "UserKnownHostsFile=$CDW_STATE_DIR/known_hosts.$server_id"
		-o StrictHostKeyChecking=accept-new
		-o IdentitiesOnly=yes
		-o ServerAliveInterval=30
		-o ConnectTimeout=10
	)
	[[ -f "$CDW_SSH_PRIVATE_KEY_FILE" ]] && opts+=(-i "$CDW_SSH_PRIVATE_KEY_FILE")
	printf '%s\n' "${opts[@]}"
}

# Executa um comando na VM: cdw_ssh <server_id> <usuario@ip> [comando...]
cdw_ssh() {
	local server_id="$1" target="$2"
	shift 2
	local -a opts
	mapfile -t opts < <(cdw_ssh_opts "$server_id")
	# shellcheck disable=SC2029 # o comando remoto é intencionalmente passado como texto
	ssh "${opts[@]}" "$target" "$@"
}
