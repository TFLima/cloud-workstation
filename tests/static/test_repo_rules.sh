#!/usr/bin/env bash
# Regras estáticas do repositório: modo estrito, Compose seguro e ausência de segredos.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/assert.sh
source "$ROOT/tests/lib/assert.sh"
cd "$ROOT"

echo "regras do repositório:"

missing=""
while IFS= read -r f; do
	grep -q '^set -Eeuo pipefail$' "$f" || missing+=" $f"
done < <(find scripts tests -name '*.sh' -not -path '*/lib/*' -type f | sort)
if [[ -z "$missing" ]]; then pass "todos os scripts usam set -Eeuo pipefail"; else flunk "sem modo estrito:$missing"; fi

ports="$(
	python3 - docker/compose.yaml <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
bad = []
for name, svc in (doc.get("services") or {}).items():
    for p in svc.get("ports") or []:
        s = p if isinstance(p, str) else str(p.get("host_ip", "")) + ":" + str(p.get("published", ""))
        if not s.startswith("127.0.0.1:"):
            bad.append(f"{name}:{s}")
print(" ".join(bad))
PY
)"
if [[ -z "$ports" ]]; then pass "Compose publica portas só em 127.0.0.1"; else flunk "portas expostas: $ports"; fi

if grep -nE '^\s*(privileged:\s*true|network_mode:\s*host)' docker/compose.yaml >/dev/null; then
	flunk "Compose usa privileged ou network_mode host"
else
	pass "Compose sem privileged/network_mode host"
fi

if grep -n '/var/run/docker.sock' docker/compose.yaml >/dev/null; then
	flunk "Compose monta o socket do Docker"
else
	pass "Compose não monta o socket do Docker"
fi

secret_re='(hcloud_token|password|secret|token)[[:space:]]*[:=][[:space:]]*["'\'']?[A-Za-z0-9/+_-]{16,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}'
hits="$(grep -rniE "$secret_re" --exclude-dir=.git --exclude-dir=.terraform --exclude=test_repo_rules.sh . || true)"
if [[ -z "$hits" ]]; then pass "nenhum segredo aparente no repositório"; else flunk "possíveis segredos encontrados (arquivos: $(cut -d: -f1 <<<"$hits" | sort -u | tr '\n' ' '))"; fi

# Regressão: o Compose interpola TODO serviço declarado, mesmo um fora do(s)
# perfil(is) pedidos; um perfil sem "tools" (e sem variáveis do Postgres) não
# pode falhar por causa de CDW_TOOLS_IMAGE/POSTGRES_PASSWORD não definidos.
if env -u CDW_TOOLS_IMAGE -u POSTGRES_PASSWORD docker compose -f docker/compose.yaml --profile cache config -q 2>/tmp/compose-cache-only.err; then
	pass "perfil cache sozinho não exige CDW_TOOLS_IMAGE/POSTGRES_PASSWORD"
else
	flunk "perfil cache sozinho falhou: $(cat /tmp/compose-cache-only.err)"
fi

for f in .env '*.tfstate' 'terraform.tfvars'; do
	if grep -qxF "$f" .gitignore; then pass ".gitignore cobre $f"; else flunk ".gitignore não cobre $f"; fi
done

finish
