# Fase 6 — Roteiro de validação ponta a ponta

Este roteiro **não foi executado**: ele existe para o operador rodar, passo a
passo, e anotar os resultados na seção "Registro" no fim. Cada passo marcado
com 💶 cria ou destrói algo pago e só deve ser executado por quem tem os
segredos (`HCLOUD_TOKEN`, passphrases, credenciais do R2) no próprio
computador. Os segredos nunca vão para o chat, para o Git nem para logs.

Custo esperado da sessão inteira: ver `docs/costs.md` (CX43 ≈ €0,21 por 8 h;
CPX42 ≈ €0,90) mais centavos de R2. Faça tudo na mesma tarde para a VM não
passar de uma ou duas sessões; as VMs são cobradas por hora iniciada.

## 0. Pré-requisitos (sem custo)
- [ ] `docs/operations.md`, seção "Preparação", concluída; `make init`
      termina com "Preflight: tudo pronto."
- [ ] `.env` com `RESTIC_REPOSITORY` (bucket R2 dedicado), `AWS_*`,
      `POSTGRES_PASSWORD` e `CDW_COMPOSE_PROFILES=full`.
- [ ] `CDW_TOOLS_IMAGE` apontando para a imagem publicada e **pública** no
      GHCR (ver "Contêiner de ferramentas" em `docs/operations.md`). Se ainda
      não houver imagem, use `CDW_COMPOSE_PROFILES=db,cache` e rode as
      ferramentas direto no host.
- [ ] `make check` passa na sua máquina.
- [ ] `make plan` mostra o tipo e o custo esperados (não cria nada).
- [ ] `make audit` mostra **zero** recursos antes de começar.

## 1. Provisionar e conectar 💶
Anote a hora de início de cada etapa para o registro de tempos.
1. `make up` (digite `criar`). Anote o tempo até "bootstrap concluído".
2. `make status` e `make doctor`: tudo verde, só a porta 22 aberta.
3. `make audit`: aparecem VM, firewall, chave SSH e IPv4 com o rótulo
   `project=cloud-dev-workstation`.
4. `make connect` e, depois, o VS Code Remote - SSH (`make connect-print`).
   Confira a impressão digital da primeira conexão.
5. Na VM: `id agent` (sem `sudo`/`docker`), `ls -ld ~ ~agent ~/work`
   (0711, 0700, 2775) e `cd ~/work && cdw-agent id -un` (deve imprimir
   `agent`). Isso valida o ADR-0008 numa VM real.

## 2. Stack de exemplo
O repositório só traz os serviços de infraestrutura (perfis `tools`, `db`,
`cache`); **não há app de exemplo versionado**. Crie uma mínima em `~/work`
(dentro da VM, fora do Git deste repositório):
1. `make deploy` com o perfil `full`; confira `docker compose ps` saudável e
   as portas só em `127.0.0.1`.
2. Laravel: `composer create-project laravel/laravel demo-laravel`, com
   `DB_*` e `REDIS_*` apontando para `127.0.0.1`; `php artisan migrate`.
3. FastAPI: um `main.py` com uma rota que lê/escreve no PostgreSQL e no
   Redis; `uvicorn main:app --host 127.0.0.1 --port 8000`.
4. Frontend: `npm create vite@latest demo-front` consumindo a API FastAPI;
   `npm run dev -- --host 127.0.0.1`.
5. Acesse tudo por túnel SSH (`LocalForward`), sem abrir portas.
6. Crie **dados de teste reconhecíveis**: linhas conhecidas no PostgreSQL
   (ex.: 100 linhas com um valor fixo), uma chave no Redis, um arquivo em
   `~/work`, e o login de `cdw-agent claude`/`codex` (para conferir o
   `~/.claude`/`~/.codex` no restore). Anote as contagens/hashes esperados.

## 3. Dois agentes em paralelo e métricas
1. Abra dois shells (`tmux`): `cdw-agent claude` e `cdw-agent codex`, cada
   um com uma tarefa real no demo (ex.: um escreve testes do FastAPI, o
   outro um componente do frontend).
2. Em outro painel, durante a execução: `docker stats --no-stream`,
   `free -h`, `df -h /`, `uptime`. Colete pelo menos três amostras
   (ocioso, um agente, dois agentes).
3. Confirme que um agente não lê o que é do operador:
   `cdw-agent bash -c 'cat /home/dev/.cdw-backup.env'` deve falhar
   (o arquivo só existe durante o backup; rode isto também no passo 4,
   enquanto o backup estiver rodando).

## 4. Backup 💶 (R2)
1. `make backup`. Anote o tempo e o tamanho do snapshot
   (`restic snapshots`, `restic stats`).
2. Confirme os dois snapshots: `cdw` (dados) e `cdw-state` (estado do
   OpenTofu, ADR-0007).
3. Na VM, depois do backup: `ls -la ~/.cdw-backup.env` (não deve existir; as credenciais são
   apagadas ao fim).

## 5. Destruir 💶
1. `make down`: confira que o backup roda e é verificado antes, que a lista
   de recursos e o custo residual aparecem, e digite `destruir <nome>`.
2. `make audit` e o console da Hetzner: **nenhum** servidor, IPv4 primário,
   volume ou snapshot restante. Firewall e chave SSH não são cobrados, mas
   também devem ter sido removidos.
3. Teste do guardrail (opcional, em uma segunda rodada): com o `RESTIC_*`
   inválido, `make down` deve **recusar** destruir.

## 6. Recriar e restaurar 💶
1. `make up` de novo. Anote o tempo de bootstrap.
2. `make deploy` (mesmos perfis) e depois `make restore` (digite
   `restaurar`). Anote o tempo.
3. Verificação, comparando com as anotações do passo 2.6:
   - [ ] contagem/valores do PostgreSQL iguais;
   - [ ] chave do Redis presente;
   - [ ] arquivo e apps em `~/work` presentes, `~/work` ainda `2775` e o
         `agent` consegue criar arquivos nele;
   - [ ] `~/.claude`/`~/.codex` restaurados, dono `agent`, modo `0700`, e o
         login dos agentes continua valendo;
   - [ ] demo Laravel/FastAPI/frontend sobem de novo;
   - [ ] `make doctor` e o smoke do passo 1.5 passam.

## 7. Encerrar 💶 e fechar a conta
1. `make down` e `make audit` (zero recursos); confira o console da Hetzner
   no dia seguinte também (cobrança por hora iniciada).
2. Apague do R2 o que for só de teste, se não quiser manter.
3. Preencha o registro abaixo e abra um PR com `docs/phase-6-report.md`
   (resultados, custo efetivo, tempos, pendências), seguindo o padrão dos
   relatórios das fases anteriores.

## Registro (preencher)
| Item | Valor |
|---|---|
| Tipo da VM / região | |
| Tempo de bootstrap (1ª vez / recriada) | |
| Tempo do `make backup` / tamanho do snapshot | |
| Tempo do `make restore` | |
| CPU/RAM/disco: ocioso / 1 agente / 2 agentes | |
| Horas faturadas (Hetzner) e custo efetivo | |
| Recursos restantes após `make down` | |
| Falhas encontradas e correções | |
