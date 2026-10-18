# Relatório da Fase 4 — Persistência e recuperação (2026-10-18)

## Decisão confirmada (ADR-0003)
Destino de backup: **Cloudflare R2** (sem custo de egress, 10 GB/mês grátis,
protocolo S3 nativo para o restic). Backblaze B2 fica documentado como
alternativa (`docs/costs.md`, ADR-0003) — trocar é só reconfigurar
`RESTIC_REPOSITORY`/credenciais no `.env` local, sem mudar os scripts.

## Implementado
- **`scripts/bootstrap.sh` (`step_restic`)**: restic deixou de ser instalado
  solto (`apt-get install restic` dentro de `BASE_PACKAGES`) e passou a ser
  fixado por versão (`0.16.4-2ubuntu0.24.04.3`, repositório oficial Ubuntu
  noble) e retido (`apt-mark hold`), mesmo mecanismo já usado para os
  pacotes do Docker. `bootstrap_version` local (OpenTofu) subiu de `2` para
  `3`.
- **`scripts/backup.sh` + `scripts/lib/backup-remote.sh`** (`make backup`):
  o script local valida a configuração (repositório, senha do restic com
  permissão 600 e ≥16 caracteres, credenciais S3 se aplicável), confirma SSH
  e envia as credenciais **só por stdin** para um arquivo temporário na VM
  (`~/.cdw-backup.env`, 600, nunca gravado localmente nem impresso; valores
  entre aspas simples via a nova função `shell_quote` em
  `scripts/lib/common.sh`, para não serem reinterpretados por `source`). O
  script remoto: `pg_dump -Fc` do PostgreSQL e `redis-cli SAVE` + cópia do
  `dump.rdb` do Redis (só os serviços que estiverem no ar), grava um
  manifesto JSON, envia tudo isso mais `~/work` e `~/.claude`/`~/.codex`
  como **um único snapshot** `restic backup`, aplica retenção (`forget
  --prune`, configurável) e roda `restic check --read-data-subset=5%`.
  Apaga (`shred`) as credenciais e a área de preparo ao final, com ou sem
  sucesso (`trap ... EXIT`).
- **`scripts/restore.sh` + `scripts/lib/restore-remote.sh`** (`make
  restore`): mesmo mecanismo de entrega de credenciais; exige confirmação
  digitada (`restaurar`, pois sobrescreve dados da VM atual). Restaura o
  snapshot (`CDW_RESTORE_SNAPSHOT`, padrão o mais recente) para uma área de
  preparo e só então aplica: `~/work`/dotfiles por `cp -a` (mescla) e os
  bancos de dados (`pg_restore --clean --if-exists`, substituição do
  `dump.rdb` do Redis + `docker compose restart redis`) — só se o serviço
  correspondente estiver no ar; senão o dump é preservado em
  `~/restore-pending/` para aplicação manual. Compara o `bootstrap_version`
  do manifesto do snapshot com o da VM atual e **avisa sem bloquear** em
  caso de divergência (tratamento de incompatibilidade de versões).

## Achados da revisão automática (Codex) no PR #3
Depois de abrir o PR, a revisão automática encontrou 3 problemas reais,
todos corrigidos e **reproduzidos de verdade neste sandbox** (não só lidos)
antes da correção, com um novo teste ponta a ponta confirmando cada um:
1. **Retenção nunca podava nada (P1)**: `restic forget` agrupa por
   `host,paths` por padrão; a área de preparo (`$STAGE`, via `mktemp`) tem
   um caminho diferente a cada execução, então cada snapshot virava seu
   próprio grupo de 1 — `--keep-daily`/`--keep-weekly`/`--keep-monthly`
   nunca tinha efeito. Reproduzido: dois backups seguidos mostravam dois
   grupos de "keep 1 snapshots" separados. Corrigido com
   `--group-by host,tags` (ignora o caminho); confirmado depois que os dois
   snapshots passaram a aparecer num único grupo. A mesma causa afetava a
   própria linha final de `backup-remote.sh` que imprime o snapshot
   "concluído" (`restic snapshots --latest 1` sofre do mesmo agrupamento
   por padrão) — corrigida para ordenar por data em vez de usar `--latest`.
2. **Restore do Redis não restaurava nada (P1)**: o Compose roda o Redis
   com `--appendonly yes`; copiar o `dump.rdb` e reiniciar não adianta
   porque o Redis recarrega o AOF existente, não o RDB copiado — reproduzido
   literalmente (inseri uma chave, fiz backup, inseri outra chave depois,
   restaurei, e a chave "nova" continuava lá, a do backup não voltava).
   Tentei primeiro remover o `appendonlydir` antes do restart: ainda assim o
   Redis não carregou o RDB copiado com AOF habilitado via flag de linha de
   comando (resultado: banco vazio). A causa raiz real, também descoberta
   testando: mesmo sem AOF, um `docker compose restart` manda SIGTERM, e o
   Redis salva um RDB final no desligamento — **sobrescrevendo** o
   `dump.rdb` recém-copiado antes do processo realmente reiniciar. Correção
   final, confirmada com um teste real completo (Postgres + Redis + volume
   de projetos): `docker/compose.yaml` não liga mais `--appendonly` (fica
   consistente com o próprio método de backup, que já é baseado em
   `SAVE`/RDB), e `restore-remote.sh` passou a fazer
   `docker compose stop redis && docker compose cp ... && docker compose
   start redis` (nunca `restart`), para a cópia acontecer só depois do
   processo parar de vez.
3. **`apt-mark hold` do restic não rodava se a versão já batesse (P2)**:
   numa VM que já tivesse o restic na versão certa (ex.: upgrade de uma
   Fase anterior, ou — como neste próprio sandbox — a versão já vinha
   pré-instalada), o `apt-mark hold` ficava dentro do `if` de instalação e
   nunca era chamado, deixando o pacote exposto a `unattended-upgrades`.
   Reproduzido retirando o hold manualmente e rodando o bootstrap de novo
   sem forçar reinstalação. Corrigido: o `apt-mark hold` agora roda
   incondicionalmente, fora do `if`.
- `.env.example`, `docs/operations.md`, `README.md` e `docs/adr/0003-...`
  atualizados; `Makefile` com a descrição real de `backup`/`restore`.

## Bugs reais encontrados e corrigidos nesta fase
Ao montar um ambiente local (Postgres + Redis via Compose) para testar
`backup-remote.sh`/`restore-remote.sh`, dois problemas pré-existentes
(Fase 3) apareceram:
1. **`docker/compose.yaml`: `${CDW_TOOLS_IMAGE:?...}` e
   `${POSTGRES_PASSWORD:?...}` quebravam `make deploy` mesmo em perfis que
   não usam esses serviços.** O Compose interpola **todo** serviço
   declarado no arquivo, não só os do(s) perfil(is) pedidos — então
   `CDW_COMPOSE_PROFILES=db` ou `=cache` sozinho falhava por causa de uma
   variável de um serviço (`tools`) que nem seria ativado. Corrigido
   trocando `:?` por `:-` (valor vazio) nos dois lugares; a obrigatoriedade
   real (exigir `CDW_TOOLS_IMAGE` com o perfil `tools`/`full`, exigir
   `POSTGRES_PASSWORD` com `db`/`full`) já era verificada em
   `scripts/deploy.sh` antes de chamar o Compose, então nada depende mais
   da checagem do próprio arquivo. Adicionado teste de regressão em
   `tests/static/test_repo_rules.sh` (`docker compose --profile cache
   config -q` sem nenhuma variável definida).

## Testes executados
| Teste | Onde | Resultado |
|---|---|---|
| `make check` (shellcheck, shfmt, yamllint, `tofu fmt`/`validate`, `docker compose config` em todos os perfis, suíte de testes) | local | OK |
| `scripts/bootstrap.sh` 3x (idempotência, incluindo forçar um downgrade manual do restic para provar que o `step_restic` reinstala e re-retém a versão fixada) + `tests/smoke/check-bootstrap.sh` (com a nova checagem de versão/hold do restic) | local (usuário `dev` simulando o runner do CI) | OK |
| **Backup e restore ponta a ponta**: `docker compose --profile db --profile cache up -d` local (Postgres/Redis reais), dados de teste inseridos (tabela, chave Redis, arquivo em `~/work`), `backup-remote.sh` rodado contra um repositório restic **local** (backend de arquivo, não R2 — sem credenciais reais disponíveis nesta sessão; a lógica do restic para S3 é a mesma, só a URL/credenciais mudam), dados apagados, `restore-remote.sh` rodado e os três dados confirmados restaurados (`SELECT` no Postgres, `GET` no Redis, conteúdo do arquivo) | local (Docker real) | OK |
| **Re-teste ponta a ponta após as correções da revisão do Codex** (achados #1 e #2 abaixo): novo ciclo completo backup → apagar tudo → restore com Postgres + Redis + `~/work` reais, usando o `restore-remote.sh` corrigido (`stop`/`cp`/`start` do Redis, sem AOF); os três dados voltaram corretamente | local (Docker real) | OK |
| **Retenção do restic (`--group-by host,tags`)**: dois `backup-remote.sh` seguidos contra o mesmo repositório local; confirmado que os dois snapshots passam a aparecer agrupados (antes da correção, cada um virava seu próprio grupo de 1, por causa do caminho aleatório da área de preparo) | local (restic real) | OK |
| **Relato do "último snapshot" (`sort_by(.time) \| last`)**: com dois snapshots no repositório, o comando antigo (`--latest 1`) devolvia os dois (grupos diferentes) e `.[0]` podia pegar o mais antigo; o comando corrigido devolveu só o mais recente de verdade | local (restic real) | OK |
| **`apt-mark hold` incondicional do restic**: `apt-mark unhold restic` manual seguido de `bootstrap.sh` sem forçar reinstalação (versão já batia); confirmado que o hold é reaplicado mesmo sem reinstalar (antes da correção, ficaria sem hold neste cenário) | local (sandbox com restic pré-instalado) | OK |
| Suíte de testes já existente (cloud-init, destroy-vars, hcloud, preflight, criptografia do estado, regras do repositório) | local | OK, sem regressão |

## Não validado (e por quê)
- **Backup/restore contra o Cloudflare R2 real**: não há conta/bucket R2
  nem credenciais nesta sessão; o teste ponta a ponta usou um repositório
  restic local (backend de arquivo) para validar toda a lógica dos scripts
  (dumps, manifesto, `backup`/`forget`/`check`, restore em área de preparo,
  reaplicação nos serviços). O protocolo S3 do restic é o mesmo para R2;
  só a URL do repositório e as credenciais mudam.
- **Restore em VM nova/descartável medindo tempo de recuperação** (como
  pede a Fase 4 do plano original): não executado — exigiria `make up`
  contra uma VM Hetzner real, que não foi autorizado nesta sessão. O teste
  ponta a ponta local cobre a mesma lógica de restore, mas não o tempo real
  de rede/download de um snapshot através da internet.
- **`make backup`/`restore` via SSH contra uma VM real**: os scripts locais
  (`scripts/backup.sh`/`restore.sh`) fazem SSH real e foram revisados
  linha a linha contra o padrão já usado por `deploy.sh`/`doctor.sh`, mas
  não foram executados de ponta a ponta porque isso exige uma VM Hetzner
  existente. O que foi executado de ponta a ponta é a lógica que roda
  **dentro** da VM (`backup-remote.sh`/`restore-remote.sh`), que é a parte
  que efetivamente fala com o restic/Postgres/Redis.

## Para validar de verdade (precisa da sua autorização)
1. Criar um bucket e um token de API no Cloudflare R2; preencher
   `RESTIC_REPOSITORY`/`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` e criar
   `~/.config/cdw/restic-password` conforme `docs/operations.md`.
2. `make up` (se a VM ainda não existir) e `make deploy` com os perfis
   desejados.
3. `make backup` contra o R2 real; confirmar o snapshot pelo `restic
   snapshots` (ou pelo resultado do próprio comando).
4. Opcional, para medir o cenário completo da Fase 4: destruir a VM
   (`make destroy-vm`, sem apagar o backup — ele está no R2, fora da
   Hetzner), recriá-la (`make up` + `make deploy`) e rodar `make restore`,
   medindo o tempo.

## Para a Fase 5
Ciclo de vida e controle de custos: `make down` (backup + verificação +
confirmação + destruição), diferenciação entre desligar/destruir/excluir
volumes e IPs, e guardrails de custo (TTL opcional, auditoria de recursos
órfãos).
