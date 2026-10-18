#!/usr/bin/env bash
# Verificações executadas DENTRO da VM por scripts/doctor.sh (via ssh 'bash -s').
set -Eeuo pipefail

problems=0
ok() { printf '  [ok]    %s\n' "$*"; }
fail() {
	printf '  [FALHA] %s\n' "$*"
	problems=$((problems + 1))
}

if [[ -f /etc/cdw/bootstrap-version ]]; then ok "bootstrap $(cat /etc/cdw/bootstrap-version)"; else fail "bootstrap não concluído"; fi

if docker info >/dev/null 2>&1; then ok "Docker $(docker version --format '{{.Server.Version}}')"; else fail "Docker indisponível para $(id -un)"; fi
if docker compose version >/dev/null 2>&1; then ok "Compose $(docker compose version --short)"; else fail "plugin Compose ausente"; fi

disk_pct="$(df --output=pcent / | tail -1 | tr -dc '0-9')"
if ((disk_pct < 85)); then ok "disco / em ${disk_pct}%"; else fail "disco / em ${disk_pct}% (limite 85%)"; fi

mem_avail="$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)"
if ((mem_avail >= 1024)); then ok "memória disponível ${mem_avail} MiB"; else fail "memória disponível baixa: ${mem_avail} MiB"; fi

for url in https://ghcr.io/v2/ https://github.com https://download.docker.com; do
	code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url" || true)"
	if [[ "$code" =~ ^[234] ]]; then ok "acesso a $url ($code)"; else fail "sem acesso a $url"; fi
done

exposed="$(ss -H -tln | awk '{print $4}' | grep -Ev '^(127\.|\[::1\]|::1)' | grep -Ev ':22$' || true)"
if [[ -z "$exposed" ]]; then ok "nenhuma porta além da 22 escutando fora do loopback"; else fail "portas expostas: $(tr '\n' ' ' <<<"$exposed")"; fi

if sudo -n ufw status 2>/dev/null | grep -q '^Status: active'; then ok "ufw ativo"; else fail "ufw inativo"; fi

sshd_cfg="$(sudo -n sshd -T 2>/dev/null || true)"
if grep -qx 'passwordauthentication no' <<<"$sshd_cfg"; then ok "SSH sem senha"; else fail "SSH aceita senha"; fi
if grep -qx 'permitrootlogin no' <<<"$sshd_cfg"; then ok "SSH sem root"; else fail "SSH permite root"; fi

echo
if ((problems > 0)); then
	echo "Doctor: $problems problema(s)."
	exit 1
fi
echo "Doctor: tudo certo."
