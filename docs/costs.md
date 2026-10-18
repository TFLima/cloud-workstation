# Estimativa de custos (ESTIMATIVA — conferir no momento do provisionamento)

Base: preços oficiais Hetzner pós-15/06/2026, DE/FI, sem IVA. IPv4 primário
≈ €0,50/mês (≈ €0,0007/h; fonte de terceiros, costgoat.com). A Hetzner cobra
por hora iniciada (arredonda para cima) com teto mensal; servidor desligado
continua sendo cobrado até ser **excluído**.

## Sessão de 8 horas

| Tipo  | Compute | IPv4   | Total aprox. |
|-------|---------|--------|--------------|
| CX43  | €0,20   | €0,01  | **€0,21**    |
| CPX42 | €0,89   | €0,01  | **€0,90**    |
| CCX23 | €1,10   | €0,01  | **€1,11**    |

## Mês com 22 sessões de 8 h (176 h)

| Tipo  | Sob demanda | Ligado 24/7 (teto) |
|-------|-------------|--------------------|
| CX43  | ~€4,65      | €16,49             |
| CPX42 | ~€19,73     | €69,99             |
| CCX23 | ~€24,38     | €86,49             |

## Custo residual após `make down`
- Hetzner: **€0** se servidor, IPv4 primário e nenhum snapshot/volume restarem.
  Chave SSH e firewall não são cobrados. `make down` lista recursos com rótulo
  `project=cloud-dev-workstation` antes e depois de destruir, para confirmar;
  `make audit` faz a mesma consulta a qualquer momento, sem destruir nada.
- Backup externo (fora da Hetzner): Cloudflare R2 é gratuito até 10 GB/mês e
  depois ~US$0,015/GB, sem custo de download; Backblaze B2 ~US$0,007/GB/mês
  (valores de terceiros, mecanik.dev; conferir no cadastro).
- Tráfego: 20 TB/mês incluídos na UE; irrelevante para este uso.

## Riscos de custo
- CX43 frequentemente indisponível → fallback CPX42 custa ~4x mais.
- Esquecer a VM ligada: no pior caso, o teto mensal do tipo escolhido.
  Mitigação (Fase 5, ADR-0006): `make status` mostra o custo estimado da
  sessão atual e avisa (sem destruir nada) se passar de `CDW_BUDGET_ALERT_EUR`
  ou do TTL sugerido em `CDW_SESSION_TTL_HOURS`; `make audit`/`make down`
  conferem recursos órfãos pelo rótulo do projeto.
