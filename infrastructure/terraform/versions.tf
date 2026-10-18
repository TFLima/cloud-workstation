terraform {
  # Compatível com OpenTofu >= 1.8 (ferramenta primária) e Terraform >= 1.6.
  required_version = ">= 1.6.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "= 1.70.0"
    }
  }
}
