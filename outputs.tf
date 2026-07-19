# ---------------------------------------------------------------------------
# OUTPUTS
#
# Dos usos:
#   1. operar (comandos ssh listos para copiar)
#   2. alimentar scripts/load_dataset.sh sin hardcodear IPs
#
# Nota: las IPs de acceso son de net_umstack (10.201.0.0/16). Solo se alcanzan
# con ZeroTier levantado o desde el campus.
# ---------------------------------------------------------------------------

# Los puertos de acceso reciben IPv4 e IPv6 (no se puede elegir subnet, ver
# compute.tf). No hay garantia de orden en all_fixed_ips, asi que se filtra
# por ausencia de ":" en vez de asumir que la v4 es la primera.
locals {
  lb_access_v4      = [for ip in openstack_networking_port_v2.lb_access.all_fixed_ips : ip if length(regexall(":", ip)) == 0][0]
  bastion_access_v4 = [for ip in openstack_networking_port_v2.bastion_access.all_fixed_ips : ip if length(regexall(":", ip)) == 0][0]
}

output "lb_access_ip" {
  description = "IP del load balancer en la red de acceso. Es la URL del servicio."
  value       = local.lb_access_v4
}

output "bastion_access_ip" {
  description = "IP del bastion en la red de acceso. Unico punto de entrada SSH."
  value       = local.bastion_access_v4
}

output "private_ips" {
  description = "IPs en la red privada. app y db SOLO existen aca."
  value = {
    lb      = openstack_networking_port_v2.lb.all_fixed_ips[0]
    app     = openstack_networking_port_v2.app.all_fixed_ips[0]
    db      = openstack_networking_port_v2.db.all_fixed_ips[0]
    bastion = openstack_networking_port_v2.bastion.all_fixed_ips[0]
  }
}

output "metabase_url" {
  description = "URL de Metabase, servida por el load balancer. Requiere ZeroTier."
  value       = "http://${local.lb_access_v4}"
}

output "ssh_commands" {
  description = "Comandos de acceso. app y db solo se alcanzan saltando por el bastion (-J)."
  value = {
    bastion = "ssh ubuntu@${local.bastion_access_v4}"
    lb      = "ssh -J ubuntu@${local.bastion_access_v4} ubuntu@${openstack_networking_port_v2.lb.all_fixed_ips[0]}"
    app     = "ssh -J ubuntu@${local.bastion_access_v4} ubuntu@${openstack_networking_port_v2.app.all_fixed_ips[0]}"
    db      = "ssh -J ubuntu@${local.bastion_access_v4} ubuntu@${openstack_networking_port_v2.db.all_fixed_ips[0]}"
  }
}
