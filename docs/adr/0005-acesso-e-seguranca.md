# ADR-0005 — Acesso e segurança de rede

- Status: proposto
- Data: 2026-10-17

## Decisão
- Firewall de nuvem Hetzner: entrada apenas TCP/22 a partir de `admin_cidr`
  (IP público do operador, /32); ICMP opcional. Sem outras portas.
- Firewall local (UFW) espelhando a regra, como defesa em profundidade.
- Usuário `dev` não-root com sudo; `PasswordAuthentication no`,
  `PermitRootLogin no`, `KbdInteractiveAuthentication no` aplicados pelo
  cloud-init; fail2ban opcional.
- `unattended-upgrades` para atualizações de segurança.
- Docker daemon sem TCP; serviços publicados só em `127.0.0.1`
  (lembrete: portas publicadas pelo Docker ignoram o UFW, por isso o bind
  em loopback é obrigatório e testado no `make doctor`).
- Acesso a serviços via `ssh -L` / port forwarding do VS Code.
- Se o IP do operador for dinâmico, `make up`/`make allow-ip` atualiza a regra
  com o IP atual detectado.

## Consequências
- Trocar de rede exige atualizar a regra de firewall antes de conectar.
