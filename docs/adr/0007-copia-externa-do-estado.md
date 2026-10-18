# ADR-0007 — Cópia externa do estado OpenTofu

- Status: aceito
- Data: 2026-10-18

## Contexto
O ADR-0002 previa copiar o estado criptografado para o destino dos backups a
cada `make up`/`make down`, mas isso não estava implementado: o estado
existia só em `~/.local/state/cdw/` no notebook. Perder o notebook com uma
VM no ar deixaria a VM cobrando sem estado para gerenciá-la ou destruí-la
pelo OpenTofu (sobraria só a limpeza manual por rótulo, `make audit`).

## Decisão
- O estado vai para o **mesmo repositório restic** dos backups (Cloudflare
  R2, ADR-0003), num snapshot próprio com a tag **`cdw-state`**.
- O caminho passa pela VM, como os outros backups: `scripts/backup.sh`
  envia o arquivo por stdin via SSH para `~/.cdw-state-upload/` e
  `scripts/lib/backup-remote.sh` faz o `restic backup` e apaga a cópia ao
  sair (`trap ... EXIT`). Assim o notebook **não precisa de restic** no uso
  normal.
- O arquivo já está criptografado pelo OpenTofu (AES-GCM, ADR-0002) e a VM
  nunca recebe a passphrase do estado; dentro do restic ele é criptografado
  de novo.
- Quando a cópia acontece:
  - ao fim de todo `make up` (`backup.sh --state-only`), que é quando o
    estado passa a conter a VM. Esse modo não cria snapshot `cdw`, para não
    gerar um snapshot vazio de `~/work` que viraria o `latest` do restore;
  - em todo `make backup`, e portanto também no início de `make down`.
- Depois do `make down` não há cópia nova: a VM já não existe para fazer o
  envio, e o estado que restou está vazio. A última cópia externa descreve
  uma VM destruída, o que é inofensivo (o OpenTofu a remove do estado no
  próximo `plan`).
- Falha na cópia ao fim do `make up` só gera aviso: a VM já foi criada, e
  desfazer o `up` por isso seria pior. Sem `RESTIC_REPOSITORY` definido, o
  `make up` avisa que não há cópia externa.
- Retenção: a mesma do `forget --prune --group-by host,tags`, que trata os
  snapshots `cdw-state` como um grupo separado dos `cdw`.

## Alternativas descartadas
- `restic` rodando no notebook depois do `apply`/`destroy`: exige restic e as
  credenciais do R2 no notebook a cada uso. Fica só para a recuperação.
- `rclone`/S3 direto para o bucket: mais uma ferramenta e um segundo formato
  no bucket, sem a deduplicação nem a verificação do restic.
- Backend remoto S3 do OpenTofu: continua como evolução opcional (ADR-0002).

## Consequências
- Recuperar o estado num computador novo exige restic local uma vez, a
  senha do repositório restic e a passphrase do estado (passo a passo em
  `docs/operations.md`, "Recuperar o estado em outro computador").
- Cada `make backup` gera dois snapshots (`cdw` e `cdw-state`); o
  `make restore` filtra por `--tag cdw` e ignora os de estado.
