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
