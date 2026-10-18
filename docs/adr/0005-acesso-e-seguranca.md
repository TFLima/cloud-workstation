# ADR-0005 — Acesso e segurança de rede

- Status: proposto
- Data: 2026-10-17

## Decisão
- Firewall de nuvem Hetzner: entrada apenas TCP/22 a partir de `admin_cidr`
  (IP público do operador, /32); ICMP opcional. Sem outras portas.
- Firewall local (UFW) como defesa em profundidade: nega toda entrada exceto
  `22/tcp` (`ufw allow`). A origem não é fixada no UFW, porque o IP do
  operador muda e o cloud-init não é reaplicado numa VM existente; quem
  restringe a origem é o firewall de nuvem. Sem `ufw limit`: ele corta um IP
  que abre 6 conexões em 30 s, e o VS Code Remote - SSH abre várias ao
  conectar e reconectar.
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
