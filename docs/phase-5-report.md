# Relatório da Fase 5 — Ciclo de vida e controle de custos (2026-10-18)

## Decisão (ADR-0006)
`make down` passa a ser o caminho seguro e recomendado para destruir a VM:
backup verificado antes, auditoria de recursos por rótulo, estimativa do
custo que deixa de ser cobrado, confirmação digitada e só então a
destruição. Guardrails de custo (TTL, alerta de orçamento) são **avisos em
`make status`, nunca destruição automática** — ver justificativa no ADR.

## Implementado
- **`scripts/lib/hcloud.sh`**: duas funções novas, somente leitura.
  `hcloud_list_labeled` consulta `servers`, `firewalls`, `ssh_keys`,
  `primary_ips`, `volumes` e `images` na API da Hetzner filtrando pelo
  rótulo `project=cloud-dev-workstation` (padrão desde a Fase 2), para achar
  recursos órfãos — mesmo volumes/snapshots, que este desenho não usa
  (ADR-0003), como rede de segurança contra algo criado fora do OpenTofu.
  `hcloud_elapsed_hours` calcula horas decorridas desde um timestamp
  ISO8601, arredondando para cima como a Hetzner cobra.
- **`scripts/destroy-safe.sh`** (`make down`): roda `make backup` primeiro
  (interrompe e destrói nada se o backup falhar; `CDW_SKIP_BACKUP=1` pula
  por conta e risco do operador), mostra os recursos do estado local, o
  custo/hora que deixa de ser cobrado, a auditoria por rótulo antes e
  depois de destruir, pede confirmação digitada (`destruir <nome>`, mesmo
  padrão do `make destroy-vm`) e só então chama `tofu destroy`.
- **`scripts/audit.sh`** (`make audit`, novo comando): lista os recursos
  com o rótulo do projeto a qualquer momento, sem depender do estado local
  nem destruir nada — útil para conferir recursos órfãos fora de um
  `make down`.
- **`scripts/status.sh`**: mostra horas decorridas desde a criação da VM e
  uma estimativa do custo da sessão atual (preço/hora da API × horas);
  avisa (sem agir) se passar de `CDW_BUDGET_ALERT_EUR` ou do
  `CDW_SESSION_TTL_HOURS` configurados no `.env` local.
- `.env.example`, `docs/operations.md`, `docs/costs.md`, `README.md` e
  `docs/adr/0006-...` atualizados; `Makefile` com `audit` e a descrição
  real de `down`.

## Sobre volumes e snapshots (Fase 5 do plano original)
O plano original pede para "diferenciar desligar, destruir VM, excluir
volumes, snapshots, IPs e outros recursos faturáveis". Este repositório
decidiu desde o ADR-0003 **não usar** volumes anexados nem snapshots da
Hetzner (`backups = false`; dados persistentes vivem em volumes Docker
locais à VM, copiados para fora pelo restic) — então não há volume ou
snapshot da Hetzner para diferenciar na destruição: o único recurso
cobrado além do servidor é o IPv4 primário, destruído junto com ele pelo
`tofu destroy`. A auditoria por rótulo (`hcloud_list_labeled`) cobre esses
tipos de recurso mesmo assim, como checagem de que nada foi criado fora
desse desenho.

## Testes executados
| Teste | Onde | Resultado |
|---|---|---|
| `make check` (shellcheck, shfmt, yamllint, `tofu fmt`/`validate`, `docker compose config`, suíte de testes) | local | OK |
| Testes unitários novos: `hcloud_list_labeled` contra uma API Hetzner falsa (mock Python, estendido para servers/firewalls/ssh_keys/primary_ips/volumes/images), `hcloud_elapsed_hours` com timestamps fixos (8h30→9h arredonda, 8h exato não arredonda) | local | OK |
| Lógica de custo da sessão (`awk` de multiplicação e de comparação usados em `status.sh`/`destroy-safe.sh`) verificada isoladamente com valores de exemplo | local | OK |
| `bash -n` nos três scripts novos/alterados (`audit.sh`, `destroy-safe.sh`, `status.sh`) | local | OK (sintaxe) |

## Não validado (e por quê)
- **`make down`/`make audit`/`make status` contra uma VM e uma conta
  Hetzner reais**: nenhuma VM existe nesta sessão (criar uma exigiria
  `make up`, não autorizado). A lógica de `destroy-safe.sh` reutiliza, linha
  a linha, os mesmos padrões já testados de ponta a ponta em
  `destroy-vm.sh` (confirmação digitada, `cdw_export_tf_vars_for_destroy`,
  `tofu destroy`) e de `backup.sh` (Fase 4, já testado ponta a ponta) — a
  parte genuinamente nova (consulta à API por rótulo, cálculo de horas e
  custo) foi testada isoladamente contra uma API Hetzner falsa e com
  aritmética verificada à mão, mas não contra a API real.
- **Um cenário real de órfão** (recurso criado fora do OpenTofu) não foi
  simulado contra a Hetzner real; o teste unitário cobre o parsing da
  resposta da API, não um caso real de drift.

## Para validar de verdade (precisa da sua autorização)
1. `make up` e, opcionalmente, deixar a VM rodando por algumas horas para
   ver `make status` mostrar o custo estimado da sessão subindo (e, se
   `CDW_SESSION_TTL_HOURS`/`CDW_BUDGET_ALERT_EUR` estiverem definidos, os
   avisos aparecerem).
2. `make audit` para confirmar que a VM/firewall/chave aparecem com o
   rótulo esperado.
3. `make down` com dados reais na VM, confirmando que: o backup roda antes
   e é verificado, a lista de recursos e o custo residual aparecem
   corretamente, a confirmação digitada é exigida, e depois de destruir
   `make audit` (ou o console da Hetzner) mostra zero recursos restantes.

## Para a Fase 6
Validação ponta a ponta: provisionar de verdade, conectar por SSH/VS Code,
subir uma stack de exemplo (Laravel + PostgreSQL + Redis + FastAPI e um
frontend), rodar dois agentes em paralelo coletando CPU/RAM/disco, fazer
backup, destruir, recriar e restaurar, confirmando que nada ficou
faturando indevidamente e registrando o custo e os tempos reais. Essa fase
depende inteiramente de autorização para provisionar infraestrutura paga.
