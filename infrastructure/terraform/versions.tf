terraform {
  # Compatível com OpenTofu >= 1.8 (ferramenta primária) e Terraform >= 1.6.
  # A criptografia do estado (OpenTofu) é configurada pela variável de ambiente
  # TF_ENCRYPTION, montada por scripts/lib/tf.sh; ver docs/adr/0002-iac-e-estado.md.
  required_version = ">= 1.6.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "= 1.70.0"
    }
  }

  # O caminho do estado é passado em `init -backend-config=path=...`,
  # fora do repositório (padrão: ~/.local/state/cdw/terraform.tfstate).
  backend "local" {}
}

# O token vem de HCLOUD_TOKEN no ambiente; nunca é uma variável Terraform.
provider "hcloud" {}
