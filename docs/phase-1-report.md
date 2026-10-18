# Relatório da Fase 1 — Repositório e qualidade (2026-10-18)

## Implementado
- Estrutura do repositório conforme o plano (seção 5), com `README.md`,
  `AGENTS.md`, `.env.example`, `.gitignore`, `.editorconfig`, `.yamllint.yaml`,
  `.opentofu-version` (1.13.1) e `requirements-dev.txt` (linters fixados).
- `scripts/lib/common.sh`: log, carregamento seguro de `.env` (sem `eval`,
  recusa permissões abertas), detecção `tofu`→`terraform`, nunca imprime segredos.
- `scripts/preflight.sh` (`make init`): dependências, variáveis obrigatórias,
  formato do token, CIDR (recusa `0.0.0.0/0`), chave pública válida (recusa
  chave privada), permissões da passphrase do estado.
- Demais scripts com `set -Eeuo pipefail` como placeholders que saem com código 2
  e indicam a fase em que serão implementados.
- `Makefile` com todos os alvos do plano; alvos de qualidade: `lint`,
  `validate`, `test`, `check`.
- OpenTofu: `versions.tf` (provider `hcloud = 1.70.0`), `variables.tf` com
  validações (localização, tipo x86_64, CIDR, chave SSH), `main.tf`/`outputs.tf`
  com rótulos de auditoria. Recursos da VM ficam para a Fase 2.
- `docker/compose.yaml`: PostgreSQL 17.6 e Redis 7.4 por perfis, portas só em
  `127.0.0.1`, senha obrigatória via ambiente, limites de memória, healthchecks.
- CI `.github/workflows/validate.yml`: sem segredos, `permissions: contents: read`,
  actions fixadas por SHA, roda `make lint validate test` com OpenTofu.

## Testes executados neste ambiente
| Comando | Resultado |
|---|---|
| `shellcheck -x` em todos os scripts | OK |
| `shfmt -d` | OK |
| `yamllint -s .` | OK |
| `terraform fmt -check` + `init -backend=false` + `validate` (Terraform 1.16.6, provider hcloud 1.70.0 via mirror local com SHA-256 conferido) | OK |
| `docker compose --profile full config -q` | OK |
| `tests/unit/test_preflight.sh` (11 asserções) | OK |
| `tests/static/test_repo_rules.sh` (8 asserções) | OK |
| Teste de mutação: porta `5432:5432`, token falso e script sem modo estrito | Os três detectados (falha esperada) |
| `preflight.sh` sem configuração | Lista 6 problemas e sai com 1, sem imprimir valores |

## Não validado (e por quê)
- **OpenTofu**: binário não baixável deste ambiente; será validado no primeiro
  run do CI (`setup-opentofu`, versão 1.13.1).
- **`.terraform.lock.hcl`**: não versionado ainda; o lock deve ser gerado com
  `tofu providers lock -platform=linux_amd64 -platform=windows_amd64` (endereços
  `registry.opentofu.org`), o que exige acesso ao registry do OpenTofu.
- **CI no GitHub**: depende de o repositório existir e do push autorizado.
- Digests das imagens Docker e imagem `Dockerfile.dev`: Fase 3.

## O que falta para a Fase 2
1. Repositório GitHub criado e autorização para o push desta branch.
2. Confirmação do destino de backup (afeta só a Fase 4).
3. Para testes reais da Fase 2 (pagos): token Hetzner configurado por você no
   `.env` local e autorização explícita para `make up`/`make down`.
