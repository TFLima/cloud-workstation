# Cloud Dev Workstation

Ambiente de desenvolvimento remoto **efêmero e reproduzível** na Hetzner Cloud:
a VM é criada sob demanda, usada via VS Code Remote SSH e destruída após um
backup externo verificado. Nada depende de snapshots do provedor.

> Estado atual: **Fase 5 (ciclo de vida e custos)**. Todos os comandos do
> plano original funcionam: `plan`, `up`, `status`, `connect`, `doctor`,
> `deploy`, `backup`, `restore`, `down` e `audit`. Falta a Fase 6
> (validação ponta a ponta contra infraestrutura real); o roteiro está em
> [`docs/phase-6-runbook.md`](docs/phase-6-runbook.md).

## Pré-requisitos (notebook Windows + WSL2 Ubuntu)
Passo a passo para iniciantes, com os comandos exatos: seção "Preparação" de
[`docs/operations.md`](docs/operations.md). Em resumo:
- VS Code com a extensão Remote - SSH (Windows).
- No WSL2: `git`, `make`, `curl`, `jq`, `openssh-client`, OpenTofu
  (versão em `.opentofu-version`). `restic` roda só na VM (instalado pelo
  bootstrap); `make backup`/`restore` não precisam dele localmente.
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
| `make push ORIGEM=... [DESTINO=...]` | Copia arquivos/pastas do WSL para `~/work` na VM, seja qual for o IP | 5 ✅ |
| `make deploy` | Stacks Docker por perfil (`tools`/`db`/`cache`/`full`) na VM | 3 ✅ |
| `make backup` / `restore` | Backup restic criptografado (fora da Hetzner) e restauração | 4 ✅ |
| `make down` | Backup verificado + auditoria de custo + confirmação + destruição | 5 ✅ |
| `make audit` | Lista recursos na Hetzner com o rótulo do projeto (achar órfãos) | 5 ✅ |
| `make doctor` | Diagnóstico de SSH, Docker, disco, memória, rede e portas | 2 ✅ |

## Copiar arquivos para a VM (o IP muda a cada `make up`)
O IP atual é lido do estado OpenTofu, então você não precisa saber qual é.

**No PowerShell do Windows** (`scripts/cdw-push.ps1`). Uma vez só, crie um
atalho `cdw-push` no seu perfil:
```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned   # se o PowerShell bloquear scripts
Unblock-File C:\Projetos\cloud-workstation\scripts\cdw-push.ps1   # se veio de um .zip
if (-not (Test-Path $PROFILE)) { New-Item -ItemType File -Force $PROFILE | Out-Null }
Add-Content $PROFILE 'Set-Alias cdw-push C:\Projetos\cloud-workstation\scripts\cdw-push.ps1'
. $PROFILE
```
(Troque `C:\Projetos\cloud-workstation` pelo caminho do seu clone.) Depois:
```powershell
cdw-push .\relatorio.pdf                        # vai para /home/dev/work/
cdw-push .\meu-projeto .\notas.txt -Dest projetos   # vai para /home/dev/work/projetos/
cdw-push *.csv -Dest dados                       # curingas funcionam
cdw-push -ConfigOnly                             # só atualiza o Host cdw (ex.: antes do VS Code)
```
O script pergunta o IP ao WSL (`scripts/vm-info.sh`), atualiza o bloco
`Host cdw` do seu `C:\Users\<você>\.ssh\config` (mantendo `IdentityFile`,
`LocalForward` etc.; a versão anterior fica em `config.bak-cdw`) e copia com
`scp -r`. Assim, `ssh cdw` e o VS Code Remote - SSH também passam a apontar
para a VM nova. Se a sua distribuição WSL não for a padrão, defina
`$env:CDW_WSL_DISTRO` (ex.: `Ubuntu-24.04`).

**No WSL:** `make push ORIGEM="arquivo pasta" DESTINO=projetos` (ou
`bash scripts/push.sh -d projetos "arquivo com espaço"`).

Chave de host: cada VM tem um `known_hosts` próprio (`known_hosts.<id>` no
estado do WSL e `~/.ssh/known_hosts.cdw.<id>` no Windows, copiado do WSL).
Uma VM nova é aceita na primeira conexão e fica fixada; uma chave diferente
para a mesma VM continua sendo recusada. A verificação nunca é desligada.

## Documentação
- Decisões: [`docs/adr/`](docs/adr/)
- Custos (estimativas): [`docs/costs.md`](docs/costs.md)
- Operação: [`docs/operations.md`](docs/operations.md)
- Relatórios de fase: [`docs/phase-0-report.md`](docs/phase-0-report.md),
  [`docs/phase-1-report.md`](docs/phase-1-report.md),
  [`docs/phase-2-report.md`](docs/phase-2-report.md),
  [`docs/phase-3-report.md`](docs/phase-3-report.md),
  [`docs/phase-4-report.md`](docs/phase-4-report.md),
  [`docs/phase-5-report.md`](docs/phase-5-report.md)

## Regras de segurança
- Nenhum segredo no Git, no estado, em imagens ou em logs.
- SSH só por chave, porta 22 restrita ao seu IP, serviços apenas em `127.0.0.1`.
- Nenhuma ação paga, publicação de imagem ou destruição sem confirmação explícita.
