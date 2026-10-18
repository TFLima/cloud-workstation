# Relatório da Fase 0 — Descoberta e decisões (2026-10-17)

## O que foi feito
1. Leitura do plano `cloud-dev-workstation-plan.md`.
2. Pesquisa de preços/disponibilidade Hetzner atuais, versões de OpenTofu,
   Terraform e provider `hcloud`, criptografia de estado e opções de backup.
3. ADRs 0001–0005 em `docs/adr/` e estimativa em `docs/costs.md`.
4. Prova de viabilidade da validação sem provisionar (ver "Testes").

## Testes executados (sem criar nada pago)
| Teste | Resultado |
|---|---|
| Download do provider `hcloud` 1.70.0 e conferência SHA-256 contra `SHA256SUMS` oficial | OK (`1dd07984…5d7c`) |
| `terraform fmt -check`, `init -backend=false` via mirror local e `validate` de um esqueleto com `hcloud_ssh_key`, `hcloud_firewall`, `hcloud_server` (ubuntu-24.04, backups=false) | OK (Terraform 1.16.6) |
| Esquema do provider contém `hcloud_server`, `hcloud_firewall`, `hcloud_ssh_key`, `hcloud_primary_ip`, `hcloud_volume` | OK |
| Instalação de shellcheck 0.11.0, shfmt 3.14.1 e yamllint 1.38.0 (via PyPI) | OK |

**Não validado:** OpenTofu (binário não baixável deste ambiente), API da
Hetzner (bloqueada pela rede deste ambiente), Docker em execução (sem daemon
aqui). Esses pontos serão validados no CI do GitHub e/ou na máquina do operador.

## Dependências identificadas
Notebook do operador (Windows): OpenSSH client, VS Code + Remote-SSH, Git,
GNU Make e Bash (recomendado: WSL2 Ubuntu, onde rodam OpenTofu, hcloud CLI,
restic, jq). VM: Ubuntu 24.04, Docker Engine + Compose plugin (repo oficial
download.docker.com), Git, restic, UFW, unattended-upgrades, agentes Claude
Code e Codex. CI: GitHub Actions com shellcheck, shfmt, tofu fmt/validate,
`docker compose config`, yamllint.

## Pendências para a Fase 1 (informações do operador)
1. Nome do repositório GitHub (e se é novo ou existente; público ou privado).
2. Região preferida e aceite do SKU (CX43 com fallback CPX42/CCX23).
3. Destino de backup externo.
4. Chave pública SSH (apenas a `.pub`).
5. Imagem de ferramentas no GHCR pública ou privada.
6. Confirmar que usará WSL2 no Windows para rodar o Makefile.
Token Hetzner, senhas restic e passphrase do estado **não** devem ser enviados
no chat; serão lidos de variáveis de ambiente/arquivos locais ignorados pelo Git.
