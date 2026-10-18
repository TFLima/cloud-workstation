# ADR-0001 — Provedor inicial e tipo de servidor

- Status: proposto (aguarda confirmação do operador)
- Data: 2026-10-17

## Contexto
Meta: 4 vCPU, 16 GB RAM, Ubuntu 24.04 x86_64, sem GPU, uso por sessões curtas.
A Hetzner reajustou preços em abril e em 15/06/2026, e a linha CX (mais barata)
tem estoque limitado: a página pública marcou CX43 como "indisponível" em
02/09, 08/09 e 13/10/2026 (fonte: stackvaluelab.com; não verificado via API).

Preços oficiais pós-15/06/2026, Alemanha/Finlândia, sem IVA e sem IPv4
(fonte: docs.hetzner.com/general/infrastructure-and-availability/price-adjustment):

| Tipo  | vCPU / RAM            | €/hora | teto €/mês | Regiões        |
|-------|-----------------------|--------|------------|----------------|
| CX43  | 8 compart. / 16 GB    | 0,0256 | 15,99      | só DE/FI       |
| CPX42 | 8 compart. / 16 GB    | 0,1114 | 69,49      | todas          |
| CCX23 | 4 dedic. / 16 GB      | 0,1378 | 85,99      | todas          |
| CAX31 | 8 ARM / 16 GB         | 0,0336 | 20,99      | só DE/FI — descartado (não é x86_64) |

## Decisão
- Hetzner Cloud, região padrão `nbg1` (alternativas `fsn1`, `hel1`).
- `server_type` e `location` são variáveis, sem valor padrão codificado no módulo.
  Ordem de preferência documentada: `cx43` → `cpx42` → `ccx23`.
- `make preflight`/`make plan` consultarão a API (`/server_types`, `/datacenters`)
  para confirmar disponibilidade e preço no momento, e falharão com mensagem clara
  se o tipo escolhido não estiver disponível.
- Imagem `ubuntu-24.04` oficial da Hetzner (não snapshot próprio).
- Portabilidade: recursos específicos do provedor ficam isolados em
  `infrastructure/terraform/`; cloud-init e scripts não dependem da Hetzner.

## Consequências
- Custo pode variar 4–5x conforme disponibilidade do CX43.
- Regiões fora da UE só aceitam CPX/CCX (mais caros) e aumentam latência para quem
  está no Brasil de forma diferente; a escolha de região é pergunta ao operador.
