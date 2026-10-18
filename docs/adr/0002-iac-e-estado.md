# ADR-0002 — Ferramenta de IaC e gestão do estado

- Status: proposto
- Data: 2026-10-17

## Decisão
- **OpenTofu** como ferramenta primária (licença MPL-2.0; última versão anunciada
  v1.13.0, 29/09/2026). Fixar versão exata em `.opentofu-version`/`versions.tf`
  na Fase 1.
- Código mantido compatível com Terraform >= 1.6 sempre que possível; a única
  dependência exclusiva do OpenTofu é a criptografia nativa de estado.
- Provider `hetznercloud/hcloud` fixado em `= 1.70.0` (última versão encontrada
  em releases.hashicorp.com em 17/10/2026), com
  `infrastructure/terraform/.terraform.lock.hcl` versionado (hashes `h1:` para
  `linux_amd64` e `windows_amd64`).
- **Estado local criptografado** com a criptografia nativa do OpenTofu
  (`key_provider "pbkdf2"` + `method "aes_gcm"`, `enforced = true` para estado e
  plano). A configuração é montada em tempo de execução na variável de ambiente
  `TF_ENCRYPTION` (scripts/lib/tf.sh) a partir de um arquivo de passphrase com
  pelo menos 16 caracteres, fora do Git. Assim o código continua válido no
  Terraform; com Terraform, os scripts recusam operar sem
  `CDW_ALLOW_UNENCRYPTED_STATE=1`.
- Backend `local` com caminho passado no `init` (`CDW_STATE_DIR`, padrão
  `~/.local/state/cdw`), fora do repositório.
- O arquivo de estado fica no notebook do operador (fora da VM e fora do Git)
  e é copiado, já criptografado, para o mesmo destino externo dos backups ao
  fim de cada `make up` e em cada `make backup`/`make down` (ADR-0007).
- Backend remoto S3 fica como evolução opcional (ADR futuro), pois exige um
  serviço pago adicional ou credenciais extras.

## Por quê
- Sem backend pago no MVP; estado pequeno (VM, chave, firewall).
- O estado contém IP e IDs; mesmo sem segredos explícitos, é tratado como sensível.
- O token Hetzner nunca é variável Terraform persistida: vem de `HCLOUD_TOKEN`
  no ambiente.

## Consequências
- Se o operador perder a passphrase, o estado é irrecuperável; mitigação:
  recursos têm rótulo `project=cloud-dev-workstation`, permitindo `tofu import`
  ou limpeza manual via `hcloud`/console.
- Uso por uma pessoa só: não há locking remoto. Documentar que não se deve
  rodar `make up/down` em dois computadores ao mesmo tempo.
