# ADR-0008 — Isolamento dos agentes de programação na VM

- Status: aceito e implementado (bootstrap versão 5)
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
- O bootstrap cria o usuário `agent` com senha bloqueada, sem `sudo`, fora do
  grupo `docker` e fora do `AllowUsers` do sshd. Um grupo `work` reúne o
  operador e `agent`. `~/work` continua em `/home/dev/work`, com dono
  `dev:work`, modo `2775` (setgid) e ACL padrão `g::rwx`, então os arquivos
  novos saem graváveis pelo grupo seja qual for o umask de quem os cria. O
  home do operador passa a `0711`: o agente atravessa até `~/work`, mas não
  lista nem lê nada fora dele (arquivos sensíveis do operador são `0600`).
- Os agentes são instalados e executados como `agent`. O comando
  `cdw-agent claude` (ou `codex`, ou `bash`) roda o comando como `agent` no
  diretório atual, com o PATH dos agentes; o operador continua entrando como
  `dev` pelo VS Code. Não há mais `claude`/`codex` em `/usr/local/bin`:
  digitar `claude` como operador falha em vez de rodar com os privilégios dele.
- O home de `agent` é `0700`. Os logins (`~/.claude`, `~/.codex`) ficam lá.
  O backup e o restore rodam como `dev` e usam `sudo` para ler e gravar esses
  dois diretórios: o backup copia para a área de preparo (removida ao sair) e o
  restore devolve com o dono `agent` e modo `0700`.
- Postgres e Redis continuam acessíveis aos agentes em `127.0.0.1`. O que eles
  perdem é controlar contêineres (`docker compose up`, `docker run`). Se isso
  fizer falta, a evolução é Docker rootless só para `agent` (ADR futuro).
- Para fazer push, o agente usa o próprio token do GitHub (fine-grained, só
  nos repositórios necessários), separado do token do operador.
- Custo: cerca de 100 linhas no bootstrap, no backup e no restore, mais testes
  (o job `bootstrap` do CI roda o script de verdade), e o passo extra
  `cdw-agent` para abrir o agente.

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
acima.

## Consequências
- `docs/operations.md` passa a mostrar `cdw-agent claude` em vez de `claude`.
- O backup e o restore passam a ler e gravar os dotfiles em `/home/agent`.
- O smoke do CI confirma que `agent` não tem sudo, não está em `docker` e
  não lê `/home/dev`.
- A VM que já existir quando esta versão sair continua com os agentes em
  `dev`: o `make up` não reaplica o bootstrap (`ignore_changes = [user_data]`).
  O isolamento vale para VMs criadas depois (`make down` + `make up`).

## Riscos que continuam
- O agente escreve em `~/work`, que o operador também usa. Um agente
  comprometido pode plantar um script, um hook do Git ou uma tarefa do VS Code
  que o operador depois executa como `dev`. Revise o que o agente deixa em
  `~/work` antes de rodar, como faria com código de terceiros.
- O agente alcança a internet e os bancos em 127.0.0.1; o que ele lê de lá, ou
  de `~/work`, pode ser enviado para fora.
- O operador continua com `sudo` sem senha: o ganho é separar os agentes dele,
  não proteger o operador de si mesmo.
