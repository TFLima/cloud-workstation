# ADR-0006 — Ciclo de vida e controle de custos

- Status: aceito
- Data: 2026-10-18

## Decisão
- **`make down`** (`scripts/destroy-safe.sh`) é a única forma recomendada de
  destruir a VM em uso normal: faz `make backup` (pode ser pulado só com
  `CDW_SKIP_BACKUP=1`, por conta e risco do operador), mostra os recursos que
  serão destruídos, uma estimativa do custo que deixa de ser cobrado e uma
  auditoria de recursos na Hetzner com o rótulo `project=cloud-dev-workstation`
  (via API, não só o que o OpenTofu acha que existe), pede confirmação
  digitada (`destruir <nome>`) e só então destrói. Se o backup falhar, a
  destruição é interrompida e nada é destruído — nunca se perde dados por uma
  falha silenciosa de backup.
- **`make destroy-vm`** continua existindo para destruir sem backup (ex.:
  recriar a VM do zero, VM de teste descartável); `make down` é o caminho
  seguro que a maioria das sessões deve usar.
- Este desenho **não usa volumes, snapshots nem IP primário avulso** da
  Hetzner (`backups = false`, decidido no ADR-0003) — então não há volume ou
  snapshot para "diferenciar" na destruição: o único recurso cobrado é a VM
  (compute) e seu IPv4 primário, ambos destruídos juntos pelo `tofu destroy`.
  A auditoria por rótulo existe mesmo assim, como rede de segurança contra
  algo criado fora do OpenTofu (ex.: manualmente no console da Hetzner).
- **Guardrails são só avisos, nunca destruição automática** (`make status`):
  - `CDW_SESSION_TTL_HOURS` (opcional): avisa quando a sessão passa desse
    número de horas; não faz nada além de sugerir `make down`.
  - `CDW_BUDGET_ALERT_EUR` (opcional): estima o custo da sessão atual
    (horas decorridas × preço/hora atual da API Hetzner) e avisa se passar
    do valor; de novo, só um aviso.
  - Nenhum TTL ou orçamento destrói a VM por conta própria — isso exigiria
    uma política explícita (ex.: rodar `make down` por um cron do próprio
    operador), que este repositório não assume por padrão, para não destruir
    uma sessão de trabalho em andamento sem intenção clara do operador.
  - Rótulo de projeto (`project=cloud-dev-workstation`) já existe desde a
    Fase 2 em todo recurso criado pelo OpenTofu; é a base da auditoria.

## Consequências
- Perder a passphrase do estado OpenTofu ainda bloqueia o `make down`
  "seguro" normal (ele precisa ler o estado para saber o que existe); nesse
  cenário, a destruição direto pelo console da Hetzner é o caminho, e o
  backup mais recente no destino restic (fora da Hetzner) seria a única
  cópia dos dados.
- A estimativa de custo em `make status`/`make down` depende da API de
  preços da Hetzner responder; se não responder, o aviso é simplesmente
  omitido (nunca bloqueia o comando).
