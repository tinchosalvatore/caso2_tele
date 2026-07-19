# ---------------------------------------------------------------------------
# CAPA DE COMPUTO
#
# Cada VM se arma en dos piezas:
#   1. un PORT (Neutron) -> es la placa de red, y es donde vive el security group
#   2. una INSTANCE (Nova) -> es la maquina, y solo referencia al port
#
# Por que port explicito y no `security_groups` en la instancia:
# openstack_compute_instance_v2 acepta `security_groups` por NOMBRE (API de
# Nova). Si se usan las dos vias a la vez, Nova y Neutron se pisan y cada plan
# muestra diferencias fantasma que nunca convergen.
# Ademas el port expone `all_fixed_ips`, que es como se le pasa a cada VM la IP
# privada de la capa de abajo sin hardcodear nada.
# ---------------------------------------------------------------------------

# --- Ports -----------------------------------------------------------------

resource "openstack_networking_port_v2" "lb" {
  name               = "${var.project_prefix}_port_lb"
  network_id         = openstack_networking_network_v2.private.id
  admin_state_up     = true
  security_group_ids = [openstack_networking_secgroup_v2.fe.id]

  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.private.id
  }
}

resource "openstack_networking_port_v2" "app" {
  name               = "${var.project_prefix}_port_app"
  network_id         = openstack_networking_network_v2.private.id
  admin_state_up     = true
  security_group_ids = [openstack_networking_secgroup_v2.app.id]

  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.private.id
  }
}

resource "openstack_networking_port_v2" "db" {
  name               = "${var.project_prefix}_port_db"
  network_id         = openstack_networking_network_v2.private.id
  admin_state_up     = true
  security_group_ids = [openstack_networking_secgroup_v2.db.id]

  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.private.id
  }
}

resource "openstack_networking_port_v2" "bastion" {
  name               = "${var.project_prefix}_port_bastion"
  network_id         = openstack_networking_network_v2.private.id
  admin_state_up     = true
  security_group_ids = [openstack_networking_secgroup_v2.bastion.id]

  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.private.id
  }
}

# --- Segundas placas: la pata en la red de acceso --------------------------
#
# SOLO lb y bastion. Esta es la decisión que sostiene toda la arquitectura:
#
#   - lb en net_umstack      -> los clientes llegan a Metabase por :80
#   - bastion en net_umstack -> el administrador llega por :22
#   - app y db NO            -> no tienen ninguna interfaz fuera de tele_net,
#                               asi que son inalcanzables salvo saltando por
#                               el bastion o pasando por el lb
#
# Si app y db tuvieran esta pata, el bastion seria decorativo y la cadena de
# confianza no existiria: cualquiera podria ir directo contra MySQL.
#
# Los security groups son LOS MISMOS que en la pata privada. Un SG aplica al
# puerto, no a la red, asi que las reglas ya escritas valen igual acá.

/*
  Sin bloque `fixed_ip`: la política del tenant lo prohíbe en esta red.
      403 PolicyNotAuthorized:
      (rule:create_port and (rule:create_port:fixed_ips
                             and (rule:create_port:fixed_ips:subnet_id)))
  O sea: podemos pedir un puerto en net_umstack, pero no elegir de qué subnet.
  Neutron asigna una IPv4 y una IPv6 GLOBAL (2600:70ff::/32).

  Consecuencia de seguridad: estas dos VMs quedan con una dirección ruteable
  desde Internet real, no solo desde la facultad.
  Lo que las protege es el security group: las reglas de OpenStack son
  ALLOW-only sobre un default DENY, y no escribimos ninguna regla ethertype
  IPv6. Por lo tanto todo el ingress v6 está denegado.
  Se verifica después del apply probando el puerto 22 sobre IPv6.
*/

resource "openstack_networking_port_v2" "lb_access" {
  name               = "${var.project_prefix}_port_lb_access"
  network_id         = data.openstack_networking_network_v2.access.id
  admin_state_up     = true
  security_group_ids = [openstack_networking_secgroup_v2.fe.id]
}

resource "openstack_networking_port_v2" "bastion_access" {
  name               = "${var.project_prefix}_port_bastion_access"
  network_id         = data.openstack_networking_network_v2.access.id
  admin_state_up     = true
  security_group_ids = [openstack_networking_secgroup_v2.bastion.id]
}

# --- user_data provisorio --------------------------------------------------
#
# Este corte solo verifica que las VMs booteen, tomen IP y tengan salida a
# Internet. La instalacion real (MySQL, Metabase, nginx) va en el corte
# siguiente, en cloud-init/*.yaml.
#
# Se separan a proposito: si se mezclan infra y configuracion en un mismo
# paso, cuando algo falle no se sabe si el problema es la red o el script.

locals {
  bootstrap_user_data = <<-EOT
    #cloud-config
    package_update: true
    packages:
      - curl
    runcmd:
      # Marca de agua: si este archivo existe, cloud-init corrio COMPLETO y
      # hubo DNS + salida a Internet (apt update tuvo que resolver y bajar).
      - [ sh, -c, "date -Is > /var/log/bootstrap-ok" ]
  EOT
}

# --- Instancias ------------------------------------------------------------
#
# El depends_on del router_interface es deliberado y es la excepcion a la
# regla "las dependencias salen solas del grafo".
# La instancia referencia al port, y el port a la subnet. En ningun lado
# referencia al router_interface. Pero SIN esa interfaz no hay ruta por
# default, y cloud-init no puede hacer apt: bootearia y fallaria en silencio.
# Es una dependencia REAL que el grafo no puede ver, por eso se declara.

resource "openstack_compute_instance_v2" "bastion" {
  name        = "${var.project_prefix}_bastion"
  image_name  = var.image_name
  flavor_name = var.flavors["bastion"]
  key_pair    = var.keypair_name
  user_data   = local.bootstrap_user_data

  # ORDEN DELIBERADO: la placa de acceso va PRIMERO.
  # Con dos interfaces, ambas piden ruta por default por DHCP y gana la de
  # menor métrica, que se asigna por orden. Si ganara tele_net, una conexión
  # SSH entrante por net_umstack intentaría responder por la otra placa:
  # ruteo asimétrico, y el anti-spoofing de Neutron descarta la respuesta.
  # Se verifica después del apply, no se asume.
  network {
    port = openstack_networking_port_v2.bastion_access.id
  }

  network {
    port = openstack_networking_port_v2.bastion.id
  }

  depends_on = [openstack_networking_router_interface_v2.main]
}

resource "openstack_compute_instance_v2" "db" {
  name        = "${var.project_prefix}_db"
  image_name  = var.image_name
  flavor_name = var.flavors["db"]
  key_pair    = var.keypair_name

  # templatefile() resuelve los ${...} del YAML con estos valores, en tiempo de
  # plan. La VM recibe el cloud-init ya completo; no hay secretos "por buscar"
  # dentro de la maquina.
  user_data = templatefile("${path.module}/cloud-init/db.yaml", {
    metabase_db_name     = var.metabase_db_name
    mobility_db_name     = var.mobility_db_name
    metabase_password    = var.db_metabase_password
    mobility_ro_password = var.db_mobility_ro_password
  })

  network {
    port = openstack_networking_port_v2.db.id
  }

  depends_on = [openstack_networking_router_interface_v2.main]
}

resource "openstack_compute_instance_v2" "app" {
  name        = "${var.project_prefix}_app"
  image_name  = var.image_name
  flavor_name = var.flavors["app"]
  key_pair    = var.keypair_name
  user_data   = local.bootstrap_user_data

  network {
    port = openstack_networking_port_v2.app.id
  }

  depends_on = [openstack_networking_router_interface_v2.main]
}

resource "openstack_compute_instance_v2" "lb" {
  name        = "${var.project_prefix}_lb"
  image_name  = var.image_name
  flavor_name = var.flavors["lb"]
  key_pair    = var.keypair_name
  user_data   = local.bootstrap_user_data

  # Mismo criterio de orden que el bastion: acceso primero.
  network {
    port = openstack_networking_port_v2.lb_access.id
  }

  network {
    port = openstack_networking_port_v2.lb.id
  }

  depends_on = [openstack_networking_router_interface_v2.main]
}
