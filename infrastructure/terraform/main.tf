locals {
  labels = {
    project    = "cloud-dev-workstation"
    managed-by = "opentofu"
  }

  bootstrap_version = "5"

  user_data = templatefile("${path.module}/../cloud-init/user-data.yaml.tftpl", {
    username          = var.username
    ssh_public_key    = trimspace(var.ssh_public_key)
    admin_cidr        = var.admin_cidr
    bootstrap_version = local.bootstrap_version
    bootstrap_b64     = base64encode(file("${path.module}/../../scripts/bootstrap.sh"))
  })
}

resource "hcloud_ssh_key" "operator" {
  name       = "${var.name}-operator"
  public_key = trimspace(var.ssh_public_key)
  labels     = local.labels
}

resource "hcloud_firewall" "workstation" {
  name   = "${var.name}-fw"
  labels = local.labels

  rule {
    description = "SSH somente do IP do operador"
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = [var.admin_cidr]
  }

  rule {
    description = "ICMP (diagnóstico) somente do IP do operador"
    direction   = "in"
    protocol    = "icmp"
    source_ips  = [var.admin_cidr]
  }
}

resource "hcloud_server" "workstation" {
  name         = var.name
  image        = var.image
  server_type  = var.server_type
  location     = var.location
  ssh_keys     = [hcloud_ssh_key.operator.id]
  firewall_ids = [hcloud_firewall.workstation.id]
  user_data    = local.user_data
  labels       = merge(local.labels, { bootstrap = local.bootstrap_version })

  # Sem backups/snapshots do provedor (ADR-0003); o IPv4 primário é criado
  # e excluído junto com o servidor, sem custo residual.
  backups            = false
  delete_protection  = false
  rebuild_protection = false

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  lifecycle {
    # Mudar o cloud-init não recria a VM existente; a VM é efêmera e o
    # bootstrap novo vale na próxima criação (make down + make up).
    ignore_changes = [user_data, ssh_keys, image]
  }
}
