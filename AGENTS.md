# Instruções para agentes de programação

Este repositório provisiona uma VM paga. Siga estas regras sempre:

1. **Nunca** execute `make up`, `make down`, `tofu apply`, `tofu destroy`,
   `hcloud ... create/delete` ou publique imagens sem autorização explícita
   do operador na conversa atual.
2. Nunca imprima, registre ou versione segredos (`HCLOUD_TOKEN`, senhas
   restic, passphrase do estado, tokens GitHub). Leia-os só do ambiente.
3. Antes de propor mudanças, rode `make check`; ele não provisiona nada.
4. Scripts Bash: `set -Eeuo pipefail`, funções de `scripts/lib/common.sh`,
   formatação `shfmt` (tabs) e `shellcheck` limpo.
5. Serviços do Compose publicam portas apenas em `127.0.0.1`.
6. Versões são fixadas (provider, OpenTofu, imagens, actions por SHA).
7. Decisões de arquitetura novas viram um ADR em `docs/adr/`.
8. Não afirme que algo foi validado se o comando não foi executado.
