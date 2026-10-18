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
  em releases.hashicorp.com em 17/10/2026), com `.terraform.lock.hcl` versionado.
- **Estado local criptografado** com a criptografia nativa do OpenTofu
  (`key_provider "pbkdf2"` + `method "aes_gcm"`), passphrase vinda de variável de
  ambiente (`TF_ENCRYPTION`/arquivo ignorado pelo Git), nunca do repositório.
- O arquivo de estado fica no notebook do operador (fora da VM e fora do Git)
  e é copiado, já criptografado, para o mesmo destino externo dos backups após
  cada `make up`/`make down`.
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
