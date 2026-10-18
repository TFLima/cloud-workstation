# ADR-0003 — Persistência e backup sem snapshots proprietários

- Status: aceito
- Data: 2026-10-17 (destino de backup confirmado em 2026-10-18, Fase 4)

## Decisão
- VM efêmera: nada de snapshots, backups automáticos da Hetzner, volumes
  anexados nem Primary IP avulso no MVP (`backups = false`; IP criado e removido
  junto com o servidor).
- Ferramenta de backup: **restic**, fixado via apt (`scripts/bootstrap.sh`,
  `step_restic`, mesmo mecanismo de `apt-mark hold` usado no Docker) —
  criptografia AES-256 nativa, deduplicação, `restic check
  --read-data-subset`, retenção com `forget --prune`, suporte nativo ao
  protocolo S3.
- Conteúdo do backup, numa única execução de `restic backup` (um snapshot
  consistente por rodada de `make backup`):
  1. dump lógico do PostgreSQL (`pg_dump -Fc`, via `docker compose exec`,
     usando as credenciais já injetadas no contêiner — nunca duplicadas no
     script de backup);
  2. snapshot do Redis (`redis-cli SAVE` síncrono + cópia de `dump.rdb`);
  3. diretório `~/work` com repositórios (inclui branches/stashes não enviados);
  4. dotfiles selecionados e estado dos agentes (`~/.claude`, `~/.codex`),
     só dentro do repositório restic criptografado;
  5. manifesto JSON (data, hostname, versão do bootstrap, versões de
     Docker/restic, lista de dumps) — usado no restore para avisar sobre
     incompatibilidade de versões.
  Os rótulos `cdw.backup` em `docker/compose.yaml` documentam essa
  convenção por volume (`pg_dump` vs. `files`); `scripts/lib/backup-remote.sh`
  e `scripts/lib/restore-remote.sh` implementam os dois serviços concretos
  (`postgres`, `redis`) deste Compose, não um motor genérico por rótulo.
- Retenção: `forget --prune` com `--keep-daily`/`--keep-weekly`/`--keep-monthly`
  configuráveis (`CDW_BACKUP_KEEP_*` no `.env` local; padrão 7/4/6), seguido de
  `restic check --read-data-subset=5%` a cada rodada.
- `make down` (Fase 5) só destrói após: backup concluído, `restic check` OK,
  snapshot listado no destino remoto e confirmação digitada pelo operador.
- Destino confirmado: **Cloudflare R2** (requisito do operador em 17/10/2026:
  o backup não pode ser cobrado nem depender do provedor da VM). Hetzner
  Object Storage e Storage Box ficam descartados por dependerem da Hetzner.
  R2 foi escolhido sobre Backblaze B2 por: (a) tier gratuito de 10 GB/mês,
  acima do volume esperado de dumps + `~/work` de um ambiente de
  desenvolvimento pessoal; (b) sem custo de egress, relevante porque um
  restore de verdade baixa o conteúdo inteiro do snapshot; (c) protocolo S3
  nativo, usado por `restic` sem driver extra (`RESTIC_REPOSITORY` no formato
  `s3:https://<account-id>.r2.cloudflarestorage.com/<bucket>`,
  `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` de um token de API R2 com acesso
  só ao bucket dedicado, `AWS_DEFAULT_REGION=auto`). B2 (~US$0,007/GB/mês,
  cobra egress) fica documentado como alternativa em `docs/costs.md` caso o
  operador prefira trocar; a troca é só reconfigurar `RESTIC_REPOSITORY` e as
  credenciais no `.env` local, sem mudar `scripts/backup.sh`/`restore.sh`.

## Mecanismo
- `scripts/backup.sh` (local) valida a configuração (`RESTIC_REPOSITORY`,
  senha com permissão 600, credenciais S3 se aplicável), confirma que a VM
  responde por SSH, envia as credenciais **só por stdin** para um arquivo
  temporário `~/.cdw-backup.env` (modo 600, nunca gravado localmente nem
  impresso; valores em aspas simples via `shell_quote` para não serem
  reinterpretados por `source`) e executa `scripts/lib/backup-remote.sh` na
  VM via `ssh ... 'bash -s' < backup-remote.sh`. O script remoto apaga o
  arquivo de credenciais (`shred -u`) e a área de preparo temporária em um
  `trap ... EXIT`, mesmo se o backup falhar no meio.
- `scripts/restore.sh` segue o mesmo mecanismo de entrega de credenciais e
  exige confirmação digitada (`restaurar`), pois sobrescreve dados da VM
  atual. Restaura primeiro para uma área de preparo (nunca direto sobre
  `~/work` ou os bancos), e só então aplica: `cp -a` para `~/work`/dotfiles
  (mescla, não apaga o que não está no snapshot) e `pg_restore
  --clean --if-exists`/substituição do `dump.rdb` do Redis. Compara o
  `bootstrap_version` do manifesto com o da VM atual e avisa (não bloqueia)
  em caso de divergência.

## Consequências
- O GitHub não é backup de volumes; repositórios locais também entram no restic.
- Senha do repositório restic fica fora da VM persistente (enviada em tempo de
  execução via SSH/arquivo temporário) e é guardada pelo operador em gerenciador
  de senhas; sem ela não há restore.
- Um restore completo em VM descartável, medindo tempo de recuperação (Fase 4
  do plano original), não foi executado nesta fase: exigiria `make up` contra
  uma VM Hetzner real e uma conta R2 real, ambos fora de autorização desta
  sessão. Ver `docs/phase-4-report.md`.
