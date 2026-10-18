#!/usr/bin/env bash
# make status: IP, estado na Hetzner, versão do bootstrap e saúde básica da VM.
set -Eeuo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/tf.sh
source "$CDW_ROOT/scripts/lib/tf.sh"
# shellcheck source=scripts/lib/hcloud.sh
source "$CDW_ROOT/scripts/lib/hcloud.sh"

cdw_load_config
cdw_setup_encryption
tf_init

if ! tf_has_server; then
	echo "Nenhuma VM no estado local ($CDW_STATE_DIR). Use make plan / make up."
	exit 0
fi

server_id="$(tf_output server_id)"
ip="$(tf_output ipv4)"
user="$(tf_output username)"
server_type="$(tf_output server_type)"
location="$(tf_output location)"
server_json="$(hcloud_get "/servers/$server_id" 2>/dev/null || true)"
# "${server_json:-{}}" não funciona: bash encerra a expansão de parâmetro no
# primeiro "}" (não faz contagem de chaves no valor padrão), então o "}" que
# fecharia o "{}" literal termina a expansão, e o "}" restante sobra colado
# ao valor — ex.: um JSON de verdade virava "...}}" com um "}" extra, que
# quebra o jq. Por isso o valor padrão é aplicado numa linha separada.
[[ -z "$server_json" ]] && server_json='{}'
api_status="$(jq -r '.server.status // "desconhecido (API)"' <<<"$server_json" 2>/dev/null)"
created="$(jq -r '.server.created // empty' <<<"$server_json" 2>/dev/null)"

echo "Servidor : $(tf_output server_name) ($server_type, $location)"
echo "Estado   : $api_status"
echo "IPv4     : $ip"
echo "Usuário  : $user"

if [[ -n "$created" ]]; then
	elapsed="$(hcloud_elapsed_hours "$created" 2>/dev/null || true)"
	if [[ -n "$elapsed" ]]; then
		# hcloud_type_price (não hcloud_check_type): o servidor já existe e já
		# está sendo cobrado, mesmo que o tipo tenha ficado sem estoque ou
		# descontinuado nesse meio tempo -- hcloud_check_type serve para
		# ESCOLHER um tipo ao provisionar e esconderia o preço/alerta de
		# orçamento exatamente nesse cenário (achado real de revisão no PR #4).
		price_result="$(hcloud_type_price "$server_type" "$location" 2>/dev/null || true)"
		cost_line="Sessão   : $elapsed h decorridas desde $created"
		if [[ -n "$price_result" ]]; then
			read -r hourly _ <<<"$price_result"
			cost="$(awk -v e="$elapsed" -v h="$hourly" 'BEGIN { printf "%.2f", e * h }')"
			cost_line+=" (~EUR $cost até agora, estimativa)"
			if [[ -n "${CDW_BUDGET_ALERT_EUR:-}" ]] && awk -v c="$cost" -v b="$CDW_BUDGET_ALERT_EUR" 'BEGIN{exit !(c>b)}'; then
				warn "custo estimado da sessão (EUR $cost) passou do alerta de orçamento (CDW_BUDGET_ALERT_EUR=$CDW_BUDGET_ALERT_EUR); considere make down"
			fi
		fi
		echo "$cost_line"
		if [[ -n "${CDW_SESSION_TTL_HOURS:-}" ]] && ((elapsed > CDW_SESSION_TTL_HOURS)); then
			warn "sessão passou do TTL sugerido (${CDW_SESSION_TTL_HOURS}h); isto é só um aviso, nada é destruído automaticamente. Considere make down"
		fi
	fi
fi

if cdw_ssh "$server_id" "$user@$ip" true 2>/dev/null; then
	cdw_ssh "$server_id" "$user@$ip" 'bash -s' <<'REMOTE'
echo "Bootstrap: $(cat /etc/cdw/bootstrap-version 2>/dev/null || echo ausente) ($(cat /etc/cdw/bootstrap-completed-at 2>/dev/null || echo '-'))"
echo "Docker   : $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo indisponível)"
echo "Compose  : $(docker compose version --short 2>/dev/null || echo indisponível)"
echo "Contêineres ativos: $(docker ps -q 2>/dev/null | wc -l)"
echo "Disco /  : $(df -h / | awk 'NR==2{print $3" usados de "$2" ("$5")"}')"
echo "Memória  : $(free -m | awk '/^Mem:/{print $3" MiB usados de "$2" MiB"}')"
echo "Uptime   : $(uptime -p)"
REMOTE
else
	echo "SSH      : sem resposta (VM desligada, firewall ou IP do operador mudou)"
fi
