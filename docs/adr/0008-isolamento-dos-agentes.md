# ADR-0008 — Isolamento dos agentes de programação na VM

- Status: aceito (implementação pendente)
- Data: 2026-10-18
- Origem: item 4.5 do relatório de revisão

## Contexto
Hoje o Claude Code e o Codex rodam como o usuário `dev`, que tem
`sudo NOPASSWD:ALL` (cloud-init) e está no grupo `docker` (equivalente a root).
Um agente que erre ou siga uma instrução maliciosa (prompt injection vinda de
um README, issue ou página web) pode, portanto:

1. virar root e alterar qualquer coisa na VM (UFW, sshd, pacotes);
2. ler tudo o que pertence a `dev`, inclusive durante o `make backup`
   o arquivo `~/.cdw-backup.env` com a senha do restic e o token do R2.
   Com esse token dá para **apagar os backups**, não só lê-los;
3. ler tokens do GitHub e de outras ferramentas guardados no `$HOME` de `dev`.

O ponto 2 é o mais grave. Ele **não** se resolve tirando o sudo, porque o
agente roda como o mesmo usuário que recebe as credenciais. Só um usuário
diferente cria essa fronteira.

O que a VM protege é pouco por desenho (efêmera, pessoal, recriada do backup),
e o código em `~/work` precisa continuar acessível aos agentes, porque é para
isso que eles existem.

## Opções

### A. Usuário `agent` separado, sem sudo e sem Docker (escolhida)
- O bootstrap cria o usuário `agent` sem senha, sem `sudo` e fora do grupo
  `docker`, e um grupo `work` com `dev` e `agent`. `~/work` passa a ser
  `/home/dev/work` com dono `dev:work`, modo `2775` (setgid) e `umask 002`
  para os dois, então os arquivos ficam editáveis por ambos.
- Os agentes são instalados e executados como `agent`. Um comando
  `cdw-agent claude` (ou `cdw-agent codex`) roda `sudo -u agent -i` no
  diretório atual; o operador continua entrando como `dev` pelo VS Code.
- Os logins (`~/.claude`, `~/.codex`) ficam no `$HOME` de `agent`, modo 750,
  grupo `dev`, para o backup (que roda como `dev`) conseguir lê-los.
  `agent` não lê nada de `dev`.
- Postgres e Redis continuam acessíveis aos agentes em `127.0.0.1`. O que eles
  perdem é controlar contêineres (`docker compose up`, `docker run`). Se isso
  fizer falta, a evolução é Docker rootless só para `agent` (ADR futuro).
- Para fazer push, o agente usa o próprio token do GitHub (fine-grained, só
  nos repositórios necessários), separado do token do operador.
- Custo: cerca de 60 linhas no bootstrap e no backup/restore, mais testes no
  CI (o job `bootstrap` já roda o script de verdade), e um passo extra para
  abrir o agente.

### B. Sudo com senha e Docker rootless, agentes ainda como `dev`
- Tira o root fácil: `sudo` passa a pedir senha, e o Docker rootless deixa de
  ser equivalente a root.
- **Não** protege as credenciais do restic/R2 nem os tokens de `dev`, que
  são o risco principal.
- Custo: senha do sudo para o operador gerenciar e migração do Compose para
  o Docker rootless.

### C. Manter como está e registrar o risco aceito
- Sem custo de implementação.
- O risco fica documentado: um agente comprometido consegue root e as
  credenciais que apagam os backups.
- Mitigação possível em qualquer opção, a verificar: uma regra de retenção
  no bucket do R2 que impeça apagar objetos por alguns dias. Isso conflita com
  o `restic forget --prune`, que precisa apagar, e exige ajustar a retenção.

## Decisão
**Opção A**, escolhida pelo operador em 2026-10-18. É a única que separa os
agentes das credenciais do backup e mantém o que eles precisam: o código em
`~/work` e os bancos em 127.0.0.1. B e C ficam descartadas pelos motivos
acima. A implementação vem num PR próprio; até lá, os agentes continuam
rodando como `dev`.

## Consequências
- `docs/operations.md` passa a mostrar `cdw-agent claude` em vez de `claude`.
- O backup e o restore passam a ler e gravar os dotfiles em `/home/agent`.
- O smoke do CI confirma que `agent` não tem sudo, não está em `docker` e
  não lê `/home/dev`.
