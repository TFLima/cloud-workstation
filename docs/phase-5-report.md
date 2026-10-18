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

## Achados da revisão automática (Codex) no PR #4
Depois de abrir o PR, a revisão automática encontrou 3 problemas reais,
todos corrigidos e verificados (testes unitários novos reproduzindo cada
cenário contra a API falsa):
1. **`status.sh` quebrava para qualquer servidor real (P1)**: o valor
   padrão `"${server_json:-{}}"` não funciona em bash — a expansão de
   parâmetro é fechada pelo primeiro `}` encontrado (bash não faz contagem
   de chaves no valor padrão), então um JSON de verdade virava
   `...}}` com uma chave sobrando no fim, o `jq` falhava, e com
   `set -e` o `make status` nunca chegava a imprimir nada para uma VM
   alcançável. Reproduzido isoladamente em bash (`x="${v:-{}}"` com `v`
   não vazio devolve `"${v}}"`, com um `}` extra). Corrigido aplicando o
   valor padrão (`'{}'`) numa linha separada em vez de dentro da própria
   expansão.
2. **Auditoria podia reportar "nada encontrado" por falha, não por estar
   vazia (P2)**: `hcloud_list_labeled` tinha um `|| true` por tipo de
   recurso, então token inválido, rede fora ou uma resposta que o `jq` não
   entende todos viravam silenciosamente "sem recursos" — no `make down`
   isso podia fazer o passo pós-destruição afirmar "custo residual: EUR 0"
   sem ter de fato confirmado nada. Corrigido: a função agora retorna
   falha (sem suprimir com `|| true`) quando qualquer consulta falha;
   `make audit` propaga isso como erro, e a checagem pós-destruição de
   `make down` agora diferencia "falha ao consultar" de "nenhum recurso
   remanescente" (a auditoria *antes* de destruir continua best-effort, já
   que o estado local serve de referência ali). Teste novo: token inválido
   faz `hcloud_list_labeled` retornar código de saída 1.
3. **Preço de um tipo sem estoque/descontinuado não entrava no cálculo de
   custo (P2)**: `hcloud_check_type` (feito para *escolher* um tipo ao
   provisionar) rejeita tipos sem estoque/descontinuados mesmo quando a API
   ainda informa o preço — um servidor já existente desse tipo (ex.: o
   próprio caso do CX43 usado como fallback) ficava sem a estimativa de
   custo e sem o alerta de `CDW_BUDGET_ALERT_EUR` em `make status`/`make
   down`. Corrigido com uma função nova, `hcloud_type_price`, que só lê o
   preço, sem as checagens de disponibilidade; `status.sh` e
   `destroy-safe.sh` passaram a usá-la para precificar um servidor que já
   existe. Teste novo: `hcloud_type_price cx43 nbg1` (tipo sem estoque
   nessa localização nas fixtures) devolve o preço normalmente.

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
| **Correções da revisão do Codex no PR #4**: `hcloud_type_price` lê o preço de um tipo sem estoque (`cx43`/`nbg1` nas fixtures) e devolve vazio para tipo inexistente; `hcloud_list_labeled` com token inválido retorna código de saída 1 em vez de "nenhum encontrado"; o bug do `"${server_json:-{}}"` foi reproduzido isoladamente em bash antes da correção | local (API falsa + bash) | OK |
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
