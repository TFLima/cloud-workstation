# Plano de implementação — Cloud Dev Workstation

## 1. Objetivo
Implementar um ambiente de desenvolvimento remoto, efêmero, reproduzível e econômico, a ser desenvolvido pelo Claude. A VM deve poder ser criada sob demanda, utilizada com VS Code Remote SSH e destruída após backup verificado, sem depender de snapshots proprietários. Priorizar agentes de programação que usam modelos remotos; GPU e LLM local ficam fora do MVP.

## 2. Premissas e decisões
- Provedor inicial: Hetzner Cloud, com camada de infraestrutura que permita migração futura. Verificar preços, tipos de instância, regiões e cotas no momento do provisionamento; não codificar nomes de planos presumidos.
- Sistema: Ubuntu 24.04 LTS x86_64.
- Meta: 4 vCPU, 16 GB RAM, SSD adequado ao trabalho; escolher o SKU disponível mais próximo. Sem GPU.
- Cliente: notebook Windows com VS Code Remote SSH e SSH por chave.
- GitHub: código, Dockerfiles, Compose, scripts, infraestrutura e configurações não secretas. GHCR: imagens OCI versionadas.
- Backups: armazenamento fora da VM e fora de imagens Docker; começar com destino local via SSH/restic ou armazenamento objeto compatível com S3. Não assumir que o GitHub é backup de volumes.
- Infraestrutura como código: Terraform ou OpenTofu, cloud-init, Bash e Makefile; preferir versões fixadas.
- Não provisionar serviços pagos sem aprovação explícita do operador.

## 3. Requisitos funcionais
1. `make init`: validar dependências, variáveis e acesso sem imprimir segredos.
2. `make plan`: exibir mudanças de infraestrutura e custo estimado (marcado como estimativa).
3. `make up`: criar VM, firewall e chave SSH autorizada, executar cloud-init idempotente, instalar Docker Engine/Compose plugin, Git, utilitários e preparar usuário não-root.
4. `make status`: mostrar IP, estado, versão do bootstrap, saúde dos serviços e recursos.
5. `make connect`: abrir ou mostrar comando SSH seguro; documentar VS Code Remote SSH.
6. `make deploy`: obter projetos/imagens do GitHub/GHCR e subir stacks Docker por perfis.
7. `make backup`: produzir dumps consistentes de PostgreSQL e cópias de volumes/dados necessários, criptografar, enviar ao destino externo, registrar manifesto e verificar integridade/recuperabilidade.
8. `make down`: realizar backup, validar confirmação externa, destruir VM e recursos cobrados vinculados. Falhar de forma segura se qualquer etapa crítica falhar. Exigir confirmação explícita para destruição.
9. `make restore`: restaurar dados em VM nova de forma controlada, com checagem de versões e permissões.
10. `make doctor`: diagnosticar SSH, Docker, espaço, memória, conectividade e dependências.

## 4. Segurança
- SSH somente por chave, usuário não-root com sudo, desabilitar login SSH por senha e acesso root remoto após bootstrap.
- Firewall de nuvem e firewall local: porta 22 restrita ao IP autorizado quando possível; não expor PostgreSQL, Redis, Docker daemon, aplicações internas ou painéis administrativos à internet.
- Preferir túnel SSH para acesso a serviços; TLS e autenticação caso publicação externa seja explicitamente solicitada.
- Segredos em gerenciador apropriado ou arquivos locais ignorados pelo Git; nunca em Terraform state versionado, logs, Dockerfile, imagem OCI ou histórico de shell.
- Estado Terraform/OpenTofu protegido e armazenado fora da VM; documentar criptografia, backup e recuperação.
- Credenciais de GHCR com menor privilégio, evitando tokens persistentes quando possível.
- Atualizações de segurança, pinagem de versões, verificações de imagens e isolamento de containers.
- Avisar antes de qualquer comando que possa exibir credenciais.

## 5. Organização proposta
```
cloud-dev-workstation/
├── README.md
├── AGENTS.md
├── Makefile
├── .gitignore
├── .env.example
├── docs/
│   ├── architecture.md
│   ├── operations.md
│   ├── security.md
│   ├── costs.md
│   └── disaster-recovery.md
├── infrastructure/
│   ├── terraform/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── versions.tf
│   └── cloud-init/
│       └── user-data.yaml
├── docker/
│   ├── Dockerfile.dev
│   └── compose.yaml
├── scripts/
│   ├── bootstrap.sh
│   ├── deploy.sh
│   ├── backup.sh
│   ├── restore.sh
│   ├── preflight.sh
│   ├── doctor.sh
│   └── destroy-safe.sh
├── config/
│   ├── ssh/
│   └── agents/
├── tests/
│   ├── smoke/
│   └── recovery/
└── .github/workflows/
    ├── build-images.yml
    └── validate.yml
```

## 6. Fases de execução para Claude

### Fase 0 — Descoberta e decisões
- Conferir documentação atual dos provedores, Terraform/OpenTofu, GitHub Packages e ferramentas de backup.
- Perguntar somente dados essenciais ausentes: conta/projeto Hetzner, região, chave pública SSH, nome do repositório, destino de backup e método de autenticação. Nunca solicitar tokens em texto no chat.
- Registrar ADRs: provedor inicial, persistência, abordagem de agentes e gestão do estado IaC.
- Estimar custo de uma sessão e custo residual após destruição.

### Fase 1 — Repositório e qualidade
- Criar estrutura, README, AGENTS.md, exemplos de variáveis e scripts com `set -Eeuo pipefail`.
- Configurar lint/testes: shellcheck, shfmt, terraform fmt/validate, validação de Compose e testes automatizados sem provisionar infraestrutura.
- Criar CI sem segredos e sem deploy automático.

### Fase 2 — Provisionamento seguro
- IaC para VM, chave SSH, firewall e outputs; variáveis para região e tamanho.
- Cloud-init idempotente para usuário não-root, Docker e dependências.
- SSH e VS Code Remote SSH documentados; preflight valida autenticação e readiness.
- Implementar `make plan`, `make up`, `make status`, `make connect`.

### Fase 3 — Ambiente de desenvolvimento
- Definir container de ferramentas (Git, PHP/Composer, Node, Python, CLIs quando compatíveis), mantendo projetos independentes.
- Compose por perfis para PostgreSQL, Redis e serviços de projetos; limites de recursos quando adequados.
- Integrar GHCR com tags imutáveis ou digests e pipeline de build.
- Instalar/configurar Codex e Claude Code por método oficial e com autenticação realizada pelo usuário; não embutir credenciais nas imagens.
- Evitar colocar projetos privados em imagens públicas.

### Fase 4 — Persistência e recuperação
- Definir inventário de dados: repositórios, dumps PostgreSQL, uploads, volumes, dotfiles selecionados, estado dos agentes e artefatos.
- Implementar backups consistentes, criptografados, com retenção configurável e destino externo.
- Nunca incluir segredos em backups não criptografados.
- Testar restore completo em VM descartável e medir tempo de recuperação.
- Tratar incompatibilidades de versões e migrações de banco.

### Fase 5 — Ciclo de vida e controle de custos
- `make down` deve executar backup, verificar conclusão, exibir recursos e custos residuais e pedir confirmação antes de destruir.
- Diferenciar desligar, destruir VM, excluir volumes, snapshots, IPs e outros recursos faturáveis.
- Guardrails: TTL opcional, alerta de orçamento, tag de projeto e auditoria de recursos órfãos.
- Evitar destruição automática por timeout sem política explícita.

### Fase 6 — Validação ponta a ponta
- Provisionar, conectar via SSH/VS Code, subir Laravel + PostgreSQL + Redis + FastAPI e um frontend de exemplo.
- Executar dois agentes de programação em paralelo e coletar CPU/RAM/disco (`docker stats`, `free`, `df`).
- Criar dados de teste, fazer backup, destruir VM, recriar e restaurar.
- Verificar que dados e configurações foram recuperados e que não restaram recursos cobrados desnecessariamente.
- Registrar custo efetivo e tempo de bootstrap/restore.

## 7. Critérios de aceitação
- Ambiente criado a partir de repositório limpo com instruções reproduzíveis.
- Nenhum segredo versionado ou embutido em imagens.
- Acesso SSH por chave e serviços internos não expostos.
- Docker e agentes funcionam; builds e testes executam na VM.
- Backup externo criptografado e restauração comprovada.
- Destruição bloqueada quando backup obrigatório falha.
- Recriação após destruição preserva os dados necessários.
- Inventário de recursos permite conferir cobrança residual.
- Documentação contém comandos de operação, troubleshooting, riscos e estimativas de custo.

## 8. Restrições e riscos
- Imagens Docker não preservam automaticamente volumes, bancos, arquivos fora dos volumes, sessões nem segredos.
- `docker commit` não substitui Dockerfiles e Compose reproduzíveis.
- GitHub/GHCR pode ter limites de armazenamento e tráfego.
- Estado IaC e backups devem sobreviver à destruição da VM.
- A restauração pode levar minutos ou mais, dependendo da velocidade da rede e do tamanho dos dados.
- Não assumir que a configuração de 4 vCPU/16 GB está disponível em todo provedor/região.

## 9. Instrução final ao Claude
Implemente por fases, mantendo mudanças em branch dedicada. Antes de executar ações pagas, publicar imagens, fazer push ou destruir recursos, apresente o plano e solicite autorização. Para cada fase, entregue arquivos, comandos de validação, resultados dos testes e pendências. Não afirme que uma operação foi validada se não foi executada. Priorize simplicidade, segurança, portabilidade e custo mínimo entre sessões.
