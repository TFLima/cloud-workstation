# ADR-0004 — Agentes de programação, imagens e GHCR

- Status: proposto
- Data: 2026-10-17

## Decisão
- **Agentes no host (usuário não-root), não na imagem.** Claude Code e Codex
  instalados pelo método oficial de cada um no bootstrap; o login é feito pelo
  operador interativamente via SSH. Credenciais nunca entram em imagem, Git ou
  log; persistem apenas no backup restic criptografado.
- **Imagem de ferramentas** (`docker/Dockerfile.dev`: Git, PHP/Composer, Node,
  Python) construída somente pelo GitHub Actions com `GITHUB_TOKEN`
  (`packages: write`) e publicada em `ghcr.io/<owner>/cdw-dev` com tags
  imutáveis (`sha-<commit>`, semver) e consumida por **digest** no Compose.
- A imagem não contém código privado nem segredos; por isso a proposta é torná-la
  **pública**, eliminando qualquer token de leitura do GHCR na VM. Se o operador
  preferir privada, a VM usará um token de leitura com escopo mínimo, informado
  em tempo de execução e não persistido (GHCR historicamente exige PAT clássico
  `read:packages`; confirmar na Fase 3).
- Serviços (PostgreSQL, Redis) usam imagens oficiais fixadas por digest, em
  perfis do Compose, ligados só em `127.0.0.1` e acessados por túnel SSH.
- Publicar imagens exige autorização explícita do operador (workflow manual na
  primeira vez).

## Consequências
- Atualizar agentes não exige rebuild de imagem.
- Builds de imagem ocorrem no GitHub, não na VM, reduzindo tempo de bootstrap.
