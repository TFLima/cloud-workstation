# Operação

## Preparação (uma vez)

### Onde cada coisa roda
Há três lugares diferentes. Quase tudo o que você digita neste guia roda no
segundo.

| Lugar | O que é | O que roda nele |
|---|---|---|
| **Windows** (seu notebook) | O sistema normal do seu computador | PowerShell (só para instalar o WSL2), VS Code com a extensão Remote - SSH |
| **WSL2 Ubuntu** (dentro do seu notebook) | Um Linux que roda dentro do Windows, no seu próprio computador. Não é um servidor e não custa nada | Este repositório, o arquivo `.env`, o OpenTofu e **todos os comandos `make`** |
| **Hetzner** (a nuvem) | O servidor pago, criado depois por `make up` | Nada que você instale à mão: o `make up` cria a VM e o bootstrap configura tudo. Você só entra nela com `make connect` ou pelo VS Code |

Resumo: você instala as ferramentas **uma vez no WSL2 Ubuntu do seu
notebook**. A Hetzner só recebe a VM que os scripts criam. Se você usa Linux
nativo no lugar do Windows, pule o passo 1 e siga do passo 2 no seu terminal.

### Passo 1: instalar o WSL2 com Ubuntu (Windows)
Requer Windows 10 (21H2 ou mais novo) ou Windows 11, com virtualização ligada
na BIOS/UEFI (na maioria dos notebooks já vem ligada).
1. Abra o menu Iniciar, procure **PowerShell**, clique com o botão direito e
   escolha **Executar como administrador**.
2. Rode `wsl --list --online` para ver as distribuições e depois instale o
   Ubuntu 24.04, que é o mesmo que a VM usa:
   ```powershell
   wsl --install -d Ubuntu-24.04
   ```
   Se o comando pedir, reinicie o computador e abra o Ubuntu de novo.
3. Na primeira abertura o Ubuntu pede um **nome de usuário** e uma **senha**
   (só para o Ubuntu local; não têm relação com a Hetzner). Anote a senha.
4. Confirme que é WSL 2: `wsl -l -v` no PowerShell deve mostrar `VERSION 2`.
5. Para abrir o Ubuntu depois: procure **Ubuntu** no menu Iniciar ou use o
   Windows Terminal. A partir daqui, **todos os comandos são digitados nesse
   terminal Ubuntu**, salvo aviso em contrário.

### Passo 2: instalar os programas no Ubuntu
```bash
sudo apt-get update
sudo apt-get install -y git make curl jq openssh-client openssl unzip restic
```
O `sudo` pede a senha do Ubuntu que você criou. O `restic` só é usado para
recuperar o estado em outro computador (veja "Backup e restore"), mas é
melhor já ter.

### Passo 3: baixar este repositório
Clone dentro da sua pasta pessoal do Ubuntu (`~`), **não** em `/mnt/c/...`:
as permissões de arquivo (`chmod 600`) que os scripts exigem não funcionam nas
pastas do Windows, e um clone feito pelo Git do Windows traz quebras de linha
CRLF (o erro típico é `set: pipefail: invalid option name`). Se isso já
aconteceu, na pasta do projeto: `git config core.autocrlf false && git rm -r -q
--cached . && git reset -q --hard` (apaga mudanças suas em arquivos versionados).
```bash
cd ~
git clone https://github.com/TFLima/cloud-workstation.git
cd cloud-workstation
```
Se o repositório for privado, o Git pede seu usuário do GitHub e, como senha,
um token de acesso pessoal do GitHub (não a senha da conta).

### Passo 4: instalar o OpenTofu
O OpenTofu é a ferramenta que cria a VM. A versão exata está no arquivo
`.opentofu-version`. Dentro da pasta do repositório:
```bash
V="$(cat .opentofu-version)"
cd "$(mktemp -d)"
curl -fsSLO "https://github.com/opentofu/opentofu/releases/download/v${V}/tofu_${V}_linux_amd64.zip"
curl -fsSLO "https://github.com/opentofu/opentofu/releases/download/v${V}/tofu_${V}_SHA256SUMS"
grep " tofu_${V}_linux_amd64.zip\$" "tofu_${V}_SHA256SUMS" | sha256sum -c -
unzip -q "tofu_${V}_linux_amd64.zip" tofu
sudo install -m 0755 tofu /usr/local/bin/tofu
cd ~/cloud-workstation
tofu version
```
A linha do `sha256sum` deve terminar com `OK`; se não, **pare** e não
instale. O último comando deve mostrar `OpenTofu v` seguido da versão do
arquivo. Este guia cobre computadores x86_64 (Intel/AMD), que são os
suportados pelo lock do provider; em ARM não siga estes passos sem antes
acrescentar `linux_arm64` ao lock.

### Passo 5: criar a chave SSH
É a chave com a qual você entra na VM. Se você já tem `~/.ssh/id_ed25519.pub`
no Ubuntu, pule. Senão:
```bash
ssh-keygen -t ed25519 -C "cdw"
```
Aceite o caminho sugerido (Enter) e escolha uma senha para a chave (ou deixe
vazia). Isso cria `~/.ssh/id_ed25519` (privada, **nunca** compartilhe) e
`~/.ssh/id_ed25519.pub` (pública, é a que vai para a VM). Para usar o VS Code,
a chave também precisa existir no Windows; veja "VS Code Remote - SSH" mais
adiante.

### Passo 6: criar o projeto e o token na Hetzner
Isso é feito no navegador, no site da Hetzner; nada é instalado.
1. Crie uma conta em <https://console.hetzner.com/>. Para criar projetos e
   servidores a Hetzner exige uma conta completa, com dados pessoais e forma
   de pagamento. Os custos estão em `docs/costs.md`; nada é cobrado até o
   `make up`.
2. No console, crie um **projeto novo e só para isto** (na tela inicial de
   projetos, o botão de novo projeto; dê um nome como `cloud-dev-workstation`
   e abra o projeto). Um projeto dedicado limita o estrago de um token
   vazado. O texto exato dos botões pode mudar; a ideia é: um projeto vazio,
   só seu.
3. Dentro do projeto, abra **Security** no menu da esquerda, depois a aba
   **API tokens** e **Generate API token**.
4. Dê uma descrição (ex.: `cdw`), escolha a permissão **Read & Write** e gere.
5. **Copie o token agora**: a Hetzner não o mostra de novo. Guarde-o no seu
   gerenciador de senhas. Não o cole em chats nem em comandos do terminal.

### Passo 7: preencher o `.env`
No Ubuntu, na pasta do repositório:
```bash
cp .env.example .env
chmod 600 .env
nano .env
```
No editor, preencha só a linha `HCLOUD_TOKEN=` colando o token logo depois do
`=`, sem aspas. Salve com `Ctrl+O`, `Enter` e saia com `Ctrl+X`. As outras
linhas já têm valores padrão adequados (região `nbg1`, tipo `cx43`, chave
`~/.ssh/id_ed25519.pub`). Não use `export HCLOUD_TOKEN=...` no terminal: o
valor ficaria no histórico de comandos.

### Passo 8: criar a passphrase do estado
O OpenTofu guarda o que sabe sobre a VM num arquivo (o "estado"), criptografado
com esta frase. Sem ela o estado não pode ser lido, então guarde uma cópia no
gerenciador de senhas:
```bash
install -d -m 700 ~/.config/cdw
(umask 077; openssl rand -base64 32 > ~/.config/cdw/state-passphrase)
clip.exe < ~/.config/cdw/state-passphrase
```
O `clip.exe` copia a frase para a área de transferência do Windows **sem
mostrá-la na tela**. Cole-a agora no gerenciador de senhas (por exemplo, numa
nota "cdw estado") e, em seguida, copie qualquer outro texto para limpar a
área de transferência. Nunca imprima essa frase com `cat` nem a cole em
chats.

### Passo 9: conferir tudo
```bash
make init
```
Deve terminar com **"Preflight: tudo pronto."** Se aparecer uma linha
`[FALHA]`, ela diz o que falta (ferramenta não instalada, variável vazia,
permissão do arquivo etc.); corrija e rode de novo. Avisos `[aviso]` não
impedem nada.

### O que ainda falta antes de destruir a VM
O backup externo (Cloudflare R2) não é necessário para criar a VM, mas o
`make down` faz backup antes de destruir e **recusa destruir se o backup
falhar** (só dá para pular por sua conta e risco). Configure-o antes de começar a trabalhar,
seguindo "Backup e restore" abaixo.

## Ciclo de uso
| Passo | Comando | Observações |
|---|---|---|
| Ver o que será criado | `make plan` | Consulta disponibilidade e preço; não cria nada. |
| Criar a VM | `make up` | Pede que você digite `criar`. Espera o bootstrap terminar e, se já existir um backup, sobe os serviços e o restaura (ver "Backup e restore"). |
| Ver estado | `make status` | IP, estado na Hetzner, versão do bootstrap, disco e memória. |
| Entrar | `make connect` | SSH com `known_hosts` próprio da VM. |
| VS Code | `make connect-print` | Copie o bloco `Host cdw` para `C:\Users\<você>\.ssh\config`. |
| Diagnóstico | `make doctor` | Falha se houver porta exposta, SSH com senha, disco cheio etc. |
| Subir ferramentas/serviços | `make deploy` | Perfis em `CDW_COMPOSE_PROFILES` (padrão `tools`); ver abaixo. |
| Backup | `make backup` | Dumps + snapshot restic criptografado fora da Hetzner; ver "Backup e restore" abaixo. |
| Restore | `make restore` | Restaura o snapshot restic na VM atual; pede confirmação. O `make up` já faz isso sozinho numa VM nova. |
| Destruir com segurança | `make down` | Backup + auditoria + confirmação + destruição; ver "Destruição" abaixo. |
| Auditoria | `make audit` | Lista recursos na Hetzner com o rótulo do projeto; não destrói nada. |

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
  imagem), num usuário próprio, `agent`, sem `sudo` e sem Docker (ADR-0008).
  Eles não leem o seu home, nem as credenciais do backup. Depois de
  `make connect`, abra-os com `cdw-agent` no diretório do projeto:
  `cdw-agent claude` (ou `cdw-agent codex`, ou `cdw-agent bash` para um shell
  do agente) e autentique na primeira vez; nada disso é persistido em imagem,
  Git ou log. Digitar só `claude` não funciona de propósito.
- **Arquivos em `~/work`** são compartilhados entre você e o agente (grupo
  `work`): os dois criam e editam. Revise o que o agente deixou (scripts,
  hooks do Git, tarefas do VS Code) antes de executar. Para o agente fazer
  push, dê a ele um token do GitHub próprio (fine-grained, só nos
  repositórios necessários), configurado dentro de `cdw-agent bash`; não
  reaproveite o seu.
- **Só VMs criadas com o bootstrap versão 5 em diante têm esse isolamento.**
  O `make up` não reaplica o bootstrap numa VM existente; use `make down` e
  `make up` para recriar.
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
  versões) e envia tudo isso mais `~/work` e o `~/.claude`/`~/.codex` do
  usuário `agent` (copiados com `sudo`) como um único snapshot `restic backup`. Depois aplica a retenção (`forget --prune`,
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

- **Restore automático no `make up`**: numa VM **recém-criada**, se o
  repositório restic já tiver um snapshot de dados (tag `cdw`), o `make up`
  roda `make deploy` e `make restore` por você, sem pedir outra confirmação
  (a VM está vazia e você já digitou `criar`). Sem backup (primeira vez), ele
  só avisa e segue. Se o `make deploy` falhar (por exemplo, falta
  `CDW_TOOLS_IMAGE` no `.env`), a restauração é pulada com um aviso: corrija
  e rode `make deploy` e `make restore`. Se a restauração falhar, o `make up`
  termina com erro, mas a VM já existe e continua cobrando. Numa VM que já
  existia, o `make up` nunca restaura. `CDW_AUTO_RESTORE=0` no `.env` desliga
  tudo isso.
- **Cópia externa do estado (ADR-0007)**: ao fim do `make up` e em todo
  `make backup`, o estado OpenTofu (já criptografado) vai para o mesmo
  repositório restic, num snapshot com a tag `cdw-state`. Uma sessão sem
  `make deploy` também tem backup: sem Compose, só os dumps são pulados.

## Recuperar o estado em outro computador
Se você perder o notebook com a VM no ar, instale restic (`sudo apt-get
install restic`), restaure a passphrase do estado e a senha do restic a
partir do gerenciador de senhas, configure o `.env` com as mesmas variáveis
`RESTIC_REPOSITORY`/`AWS_*` e rode:
```bash
set -a; source .env; set +a
export RESTIC_PASSWORD_FILE=~/.config/cdw/restic-password
restic restore latest --tag cdw-state --target /tmp/cdw-state
install -d -m 700 ~/.local/state/cdw
install -m 600 "$(find /tmp/cdw-state -name terraform.tfstate)" ~/.local/state/cdw/
rm -rf /tmp/cdw-state
```
Depois disso `make status` e `make down` funcionam de novo.

## Mudança de IP do operador
O firewall libera a porta 22 só para o IP detectado (ou `TF_VAR_admin_cidr`).
Se sua rede mudar, rode `make plan` e `make up` de novo: o OpenTofu atualiza
apenas a regra de firewall, sem recriar a VM.

## Destruição (ADR-0006)
- **`make down`** é o caminho recomendado para parar de ser cobrado: faz
  `make backup` primeiro (interrompe tudo e destrói nada se o backup
  falhar), mostra os recursos que serão destruídos, uma estimativa do custo
  que deixa de ser cobrado e uma auditoria por rótulo
  (`project=cloud-dev-workstation`) direto na API da Hetzner, pede que você
  digite `destruir <nome>` e só então destrói (VM, firewall, chave SSH e
  IPv4 primário juntos). Pular o backup: `CDW_SKIP_BACKUP=1 make down` (por
  sua conta e risco).
- **`make destroy-vm`** destrói sem fazer backup (ex.: recriar a VM do
  zero); pede confirmação (`destruir cdw`), mas não verifica nada antes.
- **`make audit`** lista, a qualquer momento, os recursos na Hetzner com o
  rótulo do projeto — útil para achar algo que sobrou (criado fora do
  OpenTofu, ou de uma destruição incompleta). Não destrói nada.
- Depois de qualquer destruição, confira no console da Hetzner que não
  restou servidor, IP primário, volume nem snapshot (este desenho não usa
  volumes/snapshots; ver ADR-0003).

## Guardrails de custo (ADR-0006)
`make status` mostra, quando a VM existe, as horas decorridas desde a
criação e uma estimativa do custo da sessão atual. Dois avisos opcionais,
configuráveis no `.env` local — **nunca destroem nada automaticamente**:
- `CDW_SESSION_TTL_HOURS`: avisa quando a sessão passa desse número de
  horas, sugerindo `make down`.
- `CDW_BUDGET_ALERT_EUR`: avisa quando o custo estimado da sessão atual
  passa desse valor em EUR.

## Onde ficam os arquivos locais
`~/.local/state/cdw/` (`CDW_STATE_DIR`): `terraform.tfstate` (criptografado),
plano salvo `cdw.tfplan` (criptografado, apagado após o `up`),
`known_hosts.<id>` e `selected-server-type`. Faça backup dessa pasta e da
passphrase; ela nunca vai para o Git.

## Logs na VM
- Bootstrap: `/var/log/cdw-bootstrap.log`; versão em `/etc/cdw/bootstrap-version`.
- cloud-init: `cloud-init status --long` e `/var/log/cloud-init-output.log`.
- Para reaplicar o bootstrap (idempotente): `sudo /usr/local/sbin/cdw-bootstrap`.
