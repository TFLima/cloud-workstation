variable "location" {
  description = "Localização Hetzner (ex.: nbg1, fsn1, hel1). Sem padrão: escolha explícita do operador."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{3}[0-9]$", var.location))
    error_message = "location deve ser um código de localização Hetzner, como nbg1."
  }
}

variable "server_type" {
  description = "Tipo de servidor Hetzner (ex.: cx43). Disponibilidade conferida pelo preflight no momento do uso."
  type        = string

  validation {
    condition     = can(regex("^c[a-z]{1,2}[0-9]{2}$", var.server_type))
    error_message = "server_type deve ser um tipo Hetzner, como cx43, cpx42 ou ccx23."
  }

  validation {
    condition     = !startswith(var.server_type, "cax")
    error_message = "Tipos ARM (cax*) não atendem ao requisito x86_64."
  }
}

variable "admin_cidr" {
  description = "CIDR IPv4 autorizado a acessar SSH (ex.: 203.0.113.10/32)."
  type        = string

  validation {
    condition     = can(cidrhost(var.admin_cidr, 0)) && var.admin_cidr != "0.0.0.0/0"
    error_message = "admin_cidr deve ser um CIDR IPv4 válido e diferente de 0.0.0.0/0."
  }
}

variable "ssh_public_key" {
  description = "Conteúdo da chave pública SSH do operador."
  type        = string

  validation {
    condition     = can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256) ", var.ssh_public_key))
    error_message = "ssh_public_key deve ser uma chave pública OpenSSH."
  }
}

variable "name" {
  description = "Prefixo dos nomes de recursos."
  type        = string
  default     = "cdw"
}

variable "username" {
  description = "Usuário não-root criado na VM."
  type        = string
  default     = "dev"

  validation {
    condition     = can(regex("^[a-z][a-z0-9_-]{1,30}$", var.username)) && var.username != "root"
    error_message = "username deve ser um nome de usuário Linux válido e diferente de root."
  }
}

variable "image" {
  description = "Imagem oficial do provedor (não snapshot próprio)."
  type        = string
  default     = "ubuntu-24.04"
}
