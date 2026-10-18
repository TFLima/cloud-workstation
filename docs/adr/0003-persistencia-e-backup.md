# ADR-0003 — Persistência e backup sem snapshots proprietários

- Status: proposto (destino depende do operador)
- Data: 2026-10-17

## Decisão
- VM efêmera: nada de snapshots, backups automáticos da Hetzner, volumes
  anexados nem Primary IP avulso no MVP (`backups = false`; IP criado e removido
  junto com o servidor).
- Ferramenta de backup: **restic** (criptografia AES-256 nativa, deduplicação,
  `restic check --read-data-subset`, retenção com `forget --prune`, suporte a
  S3 e SFTP). Versão fixada e verificada por checksum no bootstrap.
- Conteúdo do backup (inventário inicial, refinado na Fase 4):
  1. dumps lógicos PostgreSQL (`pg_dump -Fc` por banco, via `docker compose exec`);
  2. volumes Docker de dados declarados como "persistentes" no Compose
     (com serviço parado ou dump nativo);
  3. diretório `~/work` com repositórios (inclui branches/stashes não enviados);
  4. dotfiles selecionados e estado dos agentes (`~/.claude`, `~/.codex`),
     só dentro do repositório restic criptografado;
  5. manifesto JSON (data, hostname, versões, hashes, IDs de snapshot restic).
- `make down` só destrói após: backup concluído, `restic check` OK,
  snapshot listado no destino remoto e confirmação digitada pelo operador.
- Destino: **provedor independente da Hetzner** (requisito do operador em
  17/10/2026: o backup não pode ser cobrado nem depender do provedor da VM).
  Hetzner Object Storage e Storage Box ficam descartados. Candidatos via API S3:
  Cloudflare R2 (10 GB/mês grátis, sem custo de egress; recomendado) ou
  Backblaze B2 (~US$0,007/GB/mês). Escolha final registrada aqui ao ser confirmada.

## Consequências
- O GitHub não é backup de volumes; repositórios locais também entram no restic.
- Senha do repositório restic fica fora da VM persistente (enviada em tempo de
  execução via SSH/arquivo temporário) e é guardada pelo operador em gerenciador
  de senhas; sem ela não há restore.
