# Relatório da Fase 3 — Ambiente de desenvolvimento (2026-10-18)

## Correção em relação ao ADR-0004
A primeira versão de `docker/Dockerfile.dev` instalava Claude Code e Codex
**dentro da imagem** via `npm install -g`. Isso contradizia a própria decisão
do ADR-0004 ("agentes no host, não na imagem"), escrita na Fase anterior.
Corrigido: os dois CLIs saíram da imagem e passaram para
`scripts/bootstrap.sh` (host, usuário não-root, sem credenciais). O ADR foi
atualizado com o mecanismo concreto.

## Implementado
- **`docker/Dockerfile.dev`** (imagem de ferramentas, ADR-0004): Ubuntu 24.04,
  PHP 8.3.6/Composer 2.7.1 fixados via apt, Node.js 24.22.0 oficial
  (nodejs.org, SHA-256 conferido), usuário não-root `dev` (UID/GID 1000).
  `ubuntu:24.04` já tem um usuário `ubuntu` nesse mesmo UID/GID; em vez de
  escolher outro UID, o usuário existente é renomeado para `dev` e tem seus
  grupos extras (`sudo`, `adm` etc., herdados da imagem base) removidos.
- **`scripts/bootstrap.sh` (`step_agents`)**: baixa o binário oficial do
  Node.js (mesmo método e versão do Dockerfile) só para rodar
  `npm install -g` dos pacotes oficiais `@anthropic-ai/claude-code@2.1.302` e
  `@openai/codex@0.163.0` no `$HOME` do usuário não-root (prefixo isolado em
  `~/.local/share/cdw-agents`); idempotente via marcador de versões. Os
  binários são symlinkados em `/usr/local/bin` (funciona em qualquer tipo de
  shell, inclusive `ssh host comando`, que não é nem login nem interativo —
  um `.bashrc` não serviria). O login de cada CLI é feito pelo operador via
  SSH; nada é embutido em imagem, Git ou log.
- **`docker/compose.yaml`**: novo serviço `tools` (perfis `tools`/`full`),
  imagem vinda de `CDW_TOOLS_IMAGE` (variável obrigatória, preenchida após a
  primeira publicação real no GHCR), monta `CDW_PROJECTS_DIR` como
  `/home/dev/work`, limite de memória, sem portas publicadas.
- **`.github/workflows/build-images.yml`**: builda e opcionalmente publica a
  imagem no GHCR. Só roda por `workflow_dispatch` (nunca por push/PR) e só
  publica se o disparo manual marcar a entrada `push=true`; esta sessão criou
  o workflow mas **não o disparou**. O passo final imprime o digest e a linha
  `CDW_TOOLS_IMAGE=...` para colar no `.env`.
- **`scripts/deploy.sh`** (`make deploy`): envia `docker/compose.yaml` por
  `scp` e gera o `.env` da VM só por stdin via SSH (nunca grava em disco local
  nem imprime segredo), depois roda `docker compose up -d` com os perfis de
  `CDW_COMPOSE_PROFILES` (padrão `tools`).
- `.env.example`, `docs/operations.md`, `README.md` e `docs/adr/0004-...`
  atualizados.

## Revisão automática (Codex) no PR
A revisão automática do PR #2 encontrou 4 problemas reais, todos corrigidos:
1. **`codex` sem `node` no PATH persistente**: o launcher do `codex` é um
   script `#!/usr/bin/env node`; symlinkar só `claude`/`codex` em
   `/usr/local/bin` não bastava (o `claude` é um binário nativo e não
   depende disso, por isso só ele passava). Corrigido symlinkando `node`
   também. O smoke test antigo só checava `command -v` (resolve mas não
   executa); agora ele roda `--version` de verdade.
2. **`scripts/deploy.sh` sem `cdw_setup_encryption` antes do `tf_init`**:
   faltava a chamada que os demais comandos (`status.sh`, `connect.sh`) já
   fazem; sem ela o estado criptografado não seria lido. Corrigido.
3. **Senha do Postgres com `$` quebraria no Compose**: o `.env` gerado não
   escapava `$`, que o Compose interpola. Corrigido com `$$` (dotenv-safe).
4. **Pacote do GHCR nasce privado**: a VM não autentica no GHCR (a imagem é
   pensada para ser pública), então a primeira publicação falharia ao
   puxar a imagem. Documentado o passo manual (tornar o pacote público) no
   resultado do workflow e em `docs/operations.md`.

## Testes executados
| Teste | Onde | Resultado |
|---|---|---|
| `make check` (shellcheck, shfmt, yamllint, `tofu fmt`/`validate`, `docker compose config`, suíte de testes) | local | OK |
| Build real de `docker/Dockerfile.dev` ponta a ponta (PHP/Composer, extração do Node, criação/renomeação do usuário `dev`, binários funcionando) | local (Docker real) | OK, exceto o download do Node.js dentro do contexto de build, que esbarra no proxy TLS interceptador deste próprio sandbox de teste (não existe na Hetzner real nem no GitHub Actions); a lógica foi validada com uma cópia paralela (não versionada) confiando nesse proxy só para teste |
| `scripts/bootstrap.sh` completo 2x (idempotência) + `tests/smoke/check-bootstrap.sh` (20 asserções, incluindo `claude`/`codex` resolvidos via `/usr/local/bin` num shell não interativo) | local (usuário não-root simulando o runner do CI) | OK |
| Suíte de testes já existente (cloud-init, destroy-vars, hcloud, preflight, criptografia do estado, regras do repositório) | local | OK, sem regressão |

## Não validado (e por quê)
- `make deploy` e o serviço `tools` nunca rodaram contra uma VM Hetzner real
  (nenhuma VM existe nesta conversa; precisaria de `make up` autorizado antes).
- Nenhuma imagem foi publicada no GHCR: o workflow `build-images.yml` existe
  mas não foi disparado — publicar exige autorização explícita sua, que não
  foi dada nesta fase.
- `postgres`/`redis` continuam fixados por **tag** (não por digest): tentei
  resolver o digest real contra o Docker Hub a partir deste ambiente e o
  proxy do sandbox devolveu o **mesmo digest para duas imagens diferentes**
  (claramente uma resposta cacheada/errada) — por isso não gravei um digest
  que não consegui confirmar. Fica para quando alguém puder confirmar o
  digest a partir de uma rede confiável (ou a própria VM, no primeiro `make
  deploy`).
- O script oficial `curl https://claude.ai/install.sh` não foi usado porque
  `downloads.claude.ai` está bloqueado neste sandbox; o método usado
  (`npm install -g @anthropic-ai/claude-code`) também é oficialmente
  documentado e foi o que pôde ser testado de ponta a ponta aqui.

## Para validar de verdade (precisa da sua autorização)
1. `make up` (se a VM ainda não existir) e depois `make connect` para
   autenticar `claude`/`codex` interativamente uma vez.
2. Definir `POSTGRES_PASSWORD` (e `CDW_TOOLS_IMAGE`, se for usar o perfil
   `tools`) no `.env` local.
3. Disparar manualmente o workflow `build-images` no GitHub com `push=true`
   para publicar a imagem no GHCR pela primeira vez (ação que só você pode
   autorizar) e copiar o digest impresso para `CDW_TOOLS_IMAGE`.
4. **Tornar o pacote público** (o GHCR cria como privado na primeira
   publicação, e a VM não autentica no GHCR): `github.com/<owner>?tab=packages`
   → `cloud-workstation-dev` → *Package settings* → *Change visibility* →
   *Public*.
5. `make deploy` para subir os perfis escolhidos na VM.

## Para a Fase 4
Persistência e backup (restic) independente da cobrança da Hetzner — a
decisão entre Cloudflare R2 e Backblaze B2 ainda está em aberto.
