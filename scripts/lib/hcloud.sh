#!/usr/bin/env bash
# Consultas somente leitura à API da Hetzner Cloud. O token é passado ao curl
# por um arquivo de configuração anônimo (-K), nunca na linha de comando.
# Requer scripts/lib/common.sh carregado antes.

HCLOUD_API="${CDW_HCLOUD_API:-https://api.hetzner.cloud/v1}"

hcloud_get() {
	local path="$1"
	[[ -n "${HCLOUD_TOKEN:-}" ]] || die "HCLOUD_TOKEN não definido"
	curl -fsS --max-time 20 -K <(printf 'header = "Authorization: Bearer %s"\n' "$HCLOUD_TOKEN") \
		"$HCLOUD_API$path"
}

# Avalia um tipo em uma localização. Imprime "ok <preço_hora_liquido> <preço_mês_liquido>"
# ou "indisponivel <motivo>".
hcloud_check_type() {
	local type="$1" location="$2" json
	json="$(hcloud_get "/server_types?name=$type")" || {
		echo "indisponivel erro-na-api"
		return 0
	}
	jq -r --arg loc "$location" '
		.server_types[0] as $t
		| if $t == null then "indisponivel tipo-inexistente"
		  elif $t.architecture != "x86" then "indisponivel nao-x86"
		  else
		    ([$t.locations[]? | select(.name == $loc)][0]) as $l
		    | ([$t.prices[]? | select(.location == $loc)][0]) as $p
		    | if $l == null then "indisponivel nao-oferecido-em-" + $loc
		      elif ($l.deprecation != null) then "indisponivel descontinuado"
		      elif ($l.available == false) then "indisponivel sem-estoque"
		      elif $p == null then "indisponivel sem-preco"
		      else "ok \($p.price_hourly.net) \($p.price_monthly.net)"
		      end
		  end' <<<"$json"
}

# Só o preço de um tipo numa localização, sem as checagens de disponibilidade
# de hcloud_check_type (que servem para ESCOLHER um tipo ao provisionar). Para
# precificar um servidor que já existe (make status/make down), a Hetzner
# ainda cobra pelo preço mesmo que o tipo tenha ficado sem estoque ou tenha
# sido descontinuado nesse meio tempo (ex.: o próprio caso do CX43 usado como
# fallback) -- usar hcloud_check_type ali faria a estimativa de custo e o
# alerta de orçamento sumirem exatamente nesse cenário.
# Imprime "<preço_hora_liquido> <preço_mês_liquido>" ou nada (vazio) se o tipo
# não existir ou não tiver preço nessa localização.
hcloud_type_price() {
	local type="$1" location="$2" json
	json="$(hcloud_get "/server_types?name=$type" 2>/dev/null)" || return 0
	jq -r --arg loc "$location" '
		.server_types[0] as $t
		| if $t == null then empty
		  else
		    ([$t.prices[]? | select(.location == $loc)][0]) as $p
		    | if $p == null then empty
		      else "\($p.price_hourly.net) \($p.price_monthly.net)"
		      end
		  end' <<<"$json" 2>/dev/null
}

# Escolhe o primeiro tipo disponível entre o principal e as alternativas.
# Imprime "<tipo> <preço_hora> <preço_mês>" ou falha.
hcloud_select_type() {
	local location="$1" primary="$2" fallbacks="$3" candidate result
	local -a candidates=("$primary") extra=()
	IFS=',' read -r -a extra <<<"$fallbacks"
	candidates+=("${extra[@]}")
	for candidate in "${candidates[@]}"; do
		[[ -n "$candidate" ]] || continue
		result="$(hcloud_check_type "$candidate" "$location")"
		if [[ "$result" == ok* ]]; then
			read -r _ hourly monthly <<<"$result"
			printf '%s %s %s\n' "$candidate" "$hourly" "$monthly"
			return 0
		fi
		warn "$candidate em $location: ${result#indisponivel }"
	done
	return 1
}

# Preço líquido mensal do IPv4 primário na localização (ou vazio).
hcloud_ipv4_monthly() {
	local location="$1"
	hcloud_get "/pricing" 2>/dev/null | jq -r --arg loc "$location" '
		[.pricing.primary_ips[]? | select(.type == "ipv4") | .prices[]? | select(.location == $loc)][0].price_monthly.net // empty' ||
		true
}

# Lista recursos na Hetzner com o rótulo informado (padrão: o rótulo de
# projeto deste repositório), um por linha: "<tipo> <id> <nome>". Cobre
# volumes/imagens(snapshots) mesmo não sendo usados no desenho atual
# (ADR-0003/backups=false), como rede de segurança contra algo criado fora
# do OpenTofu (ex.: manualmente no console). Vazio se não houver nenhum.
# Retorna 1 se QUALQUER chamada à API ou parse falhar (token inválido, rede
# fora, endpoint com erro, resposta que o jq não entende) -- sem isso, um
# "|| true" por item transformaria toda falha em "nenhum recurso encontrado",
# o que no make audit mentiria "nenhum encontrado" e no make down deixaria o
# pós-destruição afirmar "custo residual: EUR 0" sem ter checado de verdade.
hcloud_list_labeled() {
	local label="${1:-project=cloud-dev-workstation}" kind out failed=0
	for kind in servers firewalls ssh_keys primary_ips volumes images; do
		if ! out="$(hcloud_get "/$kind?label_selector=$label" 2>/dev/null)"; then
			failed=1
			continue
		fi
		jq -r --arg k "$kind" '.[$k][]? | "\($k) \(.id) \(.name)"' <<<"$out" 2>/dev/null || failed=1
	done
	((failed == 0))
}

# Horas decorridas desde um timestamp ISO8601 UTC até agora (ou até $2, só
# para teste), arredondadas para cima como a Hetzner cobra.
hcloud_elapsed_hours() {
	local created_iso="$1" ref="${2:-}" now created
	if [[ -n "$ref" ]]; then
		now="$(date -u -d "$ref" +%s)" || return 1
	else
		now="$(date -u +%s)"
	fi
	created="$(date -u -d "$created_iso" +%s)" || return 1
	awk -v n="$now" -v c="$created" 'BEGIN { h = (n - c) / 3600; printf "%d\n", (h == int(h) ? h : int(h) + 1) }'
}
