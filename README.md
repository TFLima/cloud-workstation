# Cloud Dev Workstation

Ambiente de desenvolvimento remoto **efêmero e reproduzível** na Hetzner Cloud:
a VM é criada sob demanda, usada via VS Code Remote SSH e destruída após um
backup externo verificado. Nada depende de snapshots do provedor.

> Estado atual: **Fase 2 (provisionamento seguro)**. `plan`, `up`, `status`,
> `connect` e `doctor` funcionam; `deploy`, `backup`, `restore` e `down` vêm
> nas fases 3 a 5. Até lá, `make destroy-vm` destrói a VM sem backup.

## Pré-requisitos (notebook Windows + WSL2 Ubuntu)
- VS Code com a extensão Remote - SSH (Windows).
- No WSL2: `git`, `make`, `curl`, `jq`, `openssh-client`, OpenTofu
  (versão em `.opentofu-version`) e, a partir da Fase 4, `restic`.
- Para desenvolver este repositório: `python3 -m pip install -r requirements-dev.txt`.

## Configuração
```bash
cp .env.example .env && chmod 600 .env   # preencha sem colar tokens no chat
mkdir -p ~/.config/cdw && chmod 700 ~/.config/cdw
# crie ~/.config/cdw/state-passphrase com uma frase longa (chmod 600)
make init                                # valida tudo sem imprimir segredos
```

## Comandos
| Comando | O que faz | Fase |
|---|---|---|
| `make init` | Valida dependências, variáveis e permissões | 1 ✅ |
| `make check` | Lint, validate e testes (o mesmo que o CI) | 1 ✅ |
| `make plan` | Escolhe o tipo disponível, mostra custo estimado e o plano (não cria nada) | 2 ✅ |
| `make up` | Cria VM, firewall e chave SSH após você digitar `criar` (PAGO) | 2 ✅ |
| `make status` / `connect` / `connect-print` | Estado da VM, SSH e bloco para o VS Code | 2 ✅ |
| `make deploy` | Stacks Docker por perfil (GHCR) | 3 |
| `make backup` / `restore` | Backup restic criptografado e restauração | 4 |
| `make down` | Backup + confirmação + destruição segura | 5 |
| `make doctor` | Diagnóstico de SSH, Docker, disco, memória, rede e portas | 2 ✅ |

## Documentação
- Decisões: [`docs/adr/`](docs/adr/)
- Custos (estimativas): [`docs/costs.md`](docs/costs.md)
- Operação: [`docs/operations.md`](docs/operations.md)
- Relatórios de fase: [`docs/phase-0-report.md`](docs/phase-0-report.md),
  [`docs/phase-1-report.md`](docs/phase-1-report.md),
  [`docs/phase-2-report.md`](docs/phase-2-report.md)

## Regras de segurança
- Nenhum segredo no Git, no estado, em imagens ou em logs.
- SSH só por chave, porta 22 restrita ao seu IP, serviços apenas em `127.0.0.1`.
- Nenhuma ação paga, publicação de imagem ou destruição sem confirmação explícita.
