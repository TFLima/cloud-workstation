# Operação

## Preparação (uma vez, no WSL2 Ubuntu)
1. Instale OpenTofu na versão de `.opentofu-version`, além de `jq`, `curl`,
   `make`, `git` e `openssh-client`.
2. Crie um projeto dedicado no console da Hetzner e um token de API com
   leitura e escrita **só nesse projeto**. Guarde-o no gerenciador de senhas.
3. `cp .env.example .env && chmod 600 .env` e preencha `HCLOUD_TOKEN` editando
   o arquivo (não use `export` na linha de comando, que fica no histórico).
4. Crie a passphrase do estado (mínimo 16 caracteres) e guarde uma cópia no
   gerenciador de senhas; sem ela o estado não pode ser lido:
   ```bash
   install -d -m 700 ~/.config/cdw
   (umask 077; openssl rand -base64 32 > ~/.config/cdw/state-passphrase)
   ```
5. `make init` deve terminar com "Preflight: tudo pronto."

## Ciclo de uso
| Passo | Comando | Observações |
|---|---|---|
| Ver o que será criado | `make plan` | Consulta disponibilidade e preço; não cria nada. |
| Criar a VM | `make up` | Pede que você digite `criar`. Espera o bootstrap terminar. |
| Ver estado | `make status` | IP, estado na Hetzner, versão do bootstrap, disco e memória. |
| Entrar | `make connect` | SSH com `known_hosts` próprio da VM. |
| VS Code | `make connect-print` | Copie o bloco `Host cdw` para `C:\Users\<você>\.ssh\config`. |
| Diagnóstico | `make doctor` | Falha se houver porta exposta, SSH com senha, disco cheio etc. |
| Subir ferramentas/serviços | `make deploy` | Perfis em `CDW_COMPOSE_PROFILES` (padrão `tools`); ver abaixo. |
| Backup | `make backup` | Dumps + snapshot restic criptografado fora da Hetzner; ver "Backup e restore" abaixo. |
| Restore | `make restore` | Restaura o snapshot restic na VM atual; pede confirmação. |

## VS Code Remote - SSH (Windows)
- O VS Code usa o OpenSSH do Windows. A chave privada precisa existir no
  Windows (ex.: `C:\Users\<você>\.ssh\id_ed25519`); se ela estiver só no WSL,
  copie-a com permissões restritas ou use o agente do Windows (`ssh-add`).
- Na primeira conexão, confirme a impressão digital mostrada. Ela deve bater
  com `ssh-keygen -lf ~/.local/state/cdw/known_hosts.<id>` no WSL.
- Para serviços internos use túneis (`LocalForward 5432 127.0.0.1:5432`);
  nenhuma porta além da 22 fica aberta na internet.

## Ambiente de desenvolvimento (ADR-0004)
- **Claude Code e Codex** são instalados no host pelo bootstrap (não na
  imagem). Depois de `make connect`, autentique interativamente uma vez:
  `claude` (ou `codex`) e siga o login; nada disso é persistido em imagem,
  Git ou log.
- **Contêiner de ferramentas** (`git`, PHP/Composer, Node, Python): perfil
  `tools` do Compose, usando a imagem publicada no GHCR por
  `build-images.yml` (workflow manual; nunca publica sem alguém disparar
  `push=true`). Antes do primeiro `make deploy` com esse perfil, defina
  `CDW_TOOLS_IMAGE=ghcr.io/<owner>/cloud-workstation-dev@sha256:<digest>`
  no `.env` local (o digest sai do resultado do workflow). **O GHCR cria o
  pacote como privado na primeira publicação** e a VM não autentica no GHCR
  (a imagem é pensada para ser pública, sem token na VM); torne-o público em
  `github.com/<owner>?tab=packages` → `cloud-workstation-dev` → *Package
  settings* → *Change visibility* → *Public* antes do primeiro `make deploy`
  com o perfil `tools`.
- **PostgreSQL/Redis**: perfis `db`/`cache` (ou `full` para tudo); defina
  `POSTGRES_PASSWORD` no `.env` local antes de usá-los. As portas só ficam em
  `127.0.0.1` na VM — acesse por túnel SSH (`LocalForward 5432 127.0.0.1:5432`).
- `make deploy` envia `docker/compose.yaml` e um `.env` (gerado a partir do
  `.env` local, nunca impresso) para a VM e roda `docker compose up -d` com
  os perfis escolhidos. Rodar de novo atualiza o que mudou.

## Backup e restore (ADR-0003)
- **Preparação única**: crie um bucket no Cloudflare R2 (recomendado; sem
  custo de egress, 10 GB/mês grátis) e um token de API com acesso só a esse
  bucket. No `.env` local:
  ```
  RESTIC_REPOSITORY=s3:https://<account-id>.r2.cloudflarestorage.com/<bucket>
  AWS_ACCESS_KEY_ID=<access key do token>
  AWS_SECRET_ACCESS_KEY=<secret key do token>
  AWS_DEFAULT_REGION=auto
  ```
  Crie a senha do repositório restic (mínimo 16 caracteres) e guarde uma
  cópia no gerenciador de senhas; **sem ela não há restore**:
  ```bash
  install -d -m 700 ~/.config/cdw
  (umask 077; openssl rand -base64 32 > ~/.config/cdw/restic-password)
  ```
- **`make backup`**: na VM atual, faz `pg_dump -Fc` do PostgreSQL (se o
  perfil `db`/`full` estiver no ar) e `redis-cli SAVE` + cópia do `dump.rdb`
  (se `cache`/`full` estiver no ar), grava um manifesto (data, hostname,
  versões) e envia tudo isso mais `~/work` e `~/.claude`/`~/.codex` como um
  único snapshot `restic backup`. Depois aplica a retenção (`forget --prune`,
  configurável por `CDW_BACKUP_KEEP_DAILY`/`_WEEKLY`/`_MONTHLY` no `.env`
  local) e verifica integridade com `restic check --read-data-subset=5%`.
  As credenciais do restic são enviadas por stdin via SSH a cada execução
  (nunca gravadas na VM) e apagadas (`shred`) ao final, mesmo se o backup
  falhar.
- **`make restore`**: pede confirmação digitada (`restaurar`, pois
  sobrescreve dados da VM atual). Restaura o snapshot (`CDW_RESTORE_SNAPSHOT`
  no `.env` local; padrão o mais recente) para uma área de preparo temporária
  e só então aplica: `~/work`/dotfiles por `cp -a` (mescla; não apaga o que
  não está no snapshot) e os bancos de dados (`pg_restore --clean --if-exists`
  e substituição do `dump.rdb` do Redis seguida de `docker compose restart
  redis`) — só se o serviço correspondente estiver no ar (rode `make deploy`
  antes, se necessário). Compara a versão do bootstrap no manifesto do
  snapshot com a da VM atual e avisa (sem bloquear) em caso de divergência.
  Um dump de banco que não pôde ser aplicado (serviço fora do ar) fica em
  `~/restore-pending/` na VM para aplicação manual.

## Mudança de IP do operador
O firewall libera a porta 22 só para o IP detectado (ou `TF_VAR_admin_cidr`).
Se sua rede mudar, rode `make plan` e `make up` de novo: o OpenTofu atualiza
apenas a regra de firewall, sem recriar a VM.

## Destruição (até a Fase 5)
`make down` (backup + destruição) chega na Fase 5. Até lá, para parar a cobrança:
```bash
make destroy-vm   # pede que você digite "destruir cdw"
```
**Não há backup automático ainda**: tudo o que estiver na VM será perdido.
Depois, confira no console da Hetzner que não restou servidor nem IP primário.

## Onde ficam os arquivos locais
`~/.local/state/cdw/` (`CDW_STATE_DIR`): `terraform.tfstate` (criptografado),
plano salvo `cdw.tfplan` (criptografado, apagado após o `up`),
`known_hosts.<id>` e `selected-server-type`. Faça backup dessa pasta e da
passphrase; ela nunca vai para o Git.

## Logs na VM
- Bootstrap: `/var/log/cdw-bootstrap.log`; versão em `/etc/cdw/bootstrap-version`.
- cloud-init: `cloud-init status --long` e `/var/log/cloud-init-output.log`.
- Para reaplicar o bootstrap (idempotente): `sudo /usr/local/sbin/cdw-bootstrap`.
