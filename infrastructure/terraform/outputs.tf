output "labels" {
  description = "Rótulos aplicados a todos os recursos cobráveis, usados na auditoria de custos."
  value       = local.labels
}

output "server_id" {
  description = "ID do servidor na Hetzner."
  value       = hcloud_server.workstation.id
}

output "server_name" {
  value = hcloud_server.workstation.name
}

output "server_type" {
  value = hcloud_server.workstation.server_type
}

output "location" {
  value = hcloud_server.workstation.location
}

output "ipv4" {
  description = "IPv4 público da VM."
  value       = hcloud_server.workstation.ipv4_address
}

output "ipv6" {
  value = hcloud_server.workstation.ipv6_address
}

output "username" {
  value = var.username
}

output "bootstrap_version" {
  value = local.bootstrap_version
}
