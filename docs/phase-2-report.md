# Relatório da Fase 2 — Provisionamento seguro (2026-10-18)

## Implementado
- **OpenTofu** (`infrastructure/terraform`): `hcloud_ssh_key`, `hcloud_firewall`
  (entrada só TCP/22 e ICMP a partir de `admin_cidr`) e `hcloud_server`
  (Ubuntu 24.04 oficial, sem backups/snapshots, IPv4+IPv6, rótulos de auditoria).
  Backend local fora do repositório; estado e plano criptografados via
  `TF_ENCRYPTION` montado em tempo de execução.
- **cloud-init** (`infrastructure/cloud-init/user-data.yaml.tftpl`): cria o
  usuário `dev` com a sua chave, desliga root e senha e entrega o bootstrap.
- **Bootstrap idempotente** (`scripts/bootstrap.sh`): pacotes base, Docker
  Engine 29.9.1 + Compose 5.6.0 do repositório oficial (chave GPG conferida por
  impressão digital, versões fixadas e retidas), `daemon.json` com rotação de
  logs, SSH só por chave para `dev`, UFW, atualizações automáticas e marcador
  de versão.
- **Comandos**: `make plan` (escolhe o tipo disponível na API e mostra custo
  estimado), `make up` (pede `criar`, aplica o plano salvo e espera o bootstrap),
  `make status`, `make connect`, `make connect-print` (bloco do VS Code),
  `make doctor` (falha com porta exposta, SSH com senha, disco > 85% etc.) e
  `make destroy-vm` (pede `destruir cdw`; sem backup até a Fase 5).
- Documentação: `docs/operations.md`; ADRs 0001 e 0002 atualizados.

## Testes executados
| Teste | Onde | Resultado |
|---|---|---|
| shellcheck, shfmt, yamllint, fmt/validate, compose config | local (Terraform 1.16.6) | OK |
| Escolha de tipo contra API falsa (10 asserções: sem estoque, ARM, fallback, preço, token recusado) | local | OK |
| Criptografia do estado (8 asserções: escape, mínimo de 16 caracteres, recusa sem OpenTofu) | local | OK |
| cloud-init renderizado com `templatefile` + `cloud-init schema` (11 asserções) | local | OK |
| Preflight (13 asserções) e regras do repositório (8) | local | OK |
| `make plan` ponta a ponta contra API falsa: escolheu cpx42 com cx43 sem estoque, plano de 3 recursos, estimativa exibida; token ausente do plano salvo | local | OK |
| Bootstrap real 2x em Ubuntu 24.04 (runner do GitHub e container local) + verificação de estado (18 asserções); a 1ª rodada no CI achou e corrigiu a falta de `/run/sshd` | CI + local | OK |
| OpenTofu 1.13.1 fmt/validate e testes | CI | OK |

## Não validado (e por quê)
- `make up`, `status`, `connect`, `doctor` e `destroy-vm` contra a Hetzner real:
  criam ou dependem de recurso pago e aguardam sua autorização.
- Instalação do Docker pelo bootstrap: o runner do CI já tem Docker (pacotes
  moby que conflitam com docker-ce), então essa etapa é pulada lá e só será
  provada no primeiro `make up`.
- A chave de host SSH é aceita na primeira conexão (TOFU), com `known_hosts`
  próprio por servidor; conferir a impressão digital é manual por enquanto.

## Para validar de verdade (precisa da sua autorização)
1. No WSL: configurar `.env`, passphrase e `make init` (docs/operations.md).
2. `make plan` (gratuito), depois `make up` → VM paga (~€0,03/h no CX43 ou
   ~€0,11/h no CPX42), `make doctor`, `make connect-print` no VS Code e
   `make destroy-vm`. Uma rodada completa leva menos de 1 hora (~€0,03–0,12).
