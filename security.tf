# ---------------------------------------------------------------------------
# SECURITY GROUPS -- el corazón del TP.
#
# Cadena de confianza: cada capa habla SOLO con la adyacente.
#
#   0.0.0.0/0 --:80--> [sg_fe] --:80--> [sg_app] --:3306--> [sg_db]
#                         ^            ^                  ^
#                         |            |                  |
#                         +---- :22 ---+------ :22 -------+
#                                      |
#                                 [sg_bastion] <--:22-- admin
#
# DECISIÓN CENTRAL: las reglas se escriben con `remote_group_id`, NO con la IP
# privada de la VM de al lado.
#   - Una IP cambia si la instancia se recrea: la regla quedaría apuntando a
#     la nada, o peor, a otra VM que herede esa IP.
#   - El grupo es una identidad ESTABLE e independiente del ciclo de vida de
#     la instancia. Es lo que permite tratar a las VMs como cattle y no pets.
#
# Nota sobre egress: al crear un SG, OpenStack agrega automáticamente reglas
# de egress permisivas (IPv4 e IPv6). Se dejan a propósito: sin salida, las
# VMs no pueden hacer `apt install` ni bajar el JAR de Metabase. Es una
# decisión tomada, no un olvido. (Se podrían borrar con delete_default_rules).
# ---------------------------------------------------------------------------

# --- Los cuatro grupos -----------------------------------------------------
# Se declaran primero, sin reglas, porque las reglas se referencian entre sí.

resource "openstack_networking_secgroup_v2" "fe" {
  name        = "${var.project_prefix}_sg_fe"
  description = "Front-end / load balancer nginx. Unica capa expuesta en HTTP."
}

resource "openstack_networking_secgroup_v2" "app" {
  name        = "${var.project_prefix}_sg_app"
  description = "Aplicacion Metabase. Solo alcanzable desde el load balancer."
}

resource "openstack_networking_secgroup_v2" "db" {
  name        = "${var.project_prefix}_sg_db"
  description = "MySQL. Capa mas interna, solo alcanzable desde la aplicacion."
}

resource "openstack_networking_secgroup_v2" "bastion" {
  name        = "${var.project_prefix}_sg_bastion"
  description = "Bastion SSH. Unico punto de entrada del plano de gestion."
}

# ---------------------------------------------------------------------------
# sg_fe -- el único que acepta tráfico del mundo
# ---------------------------------------------------------------------------

resource "openstack_networking_secgroup_rule_v2" "fe_http_from_world" {
  security_group_id = openstack_networking_secgroup_v2.fe.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 80
  port_range_max    = 80

  # El único CIDR abierto del lado del servicio. Lo pide el diagrama: el LB
  # es el punto de entrada público. Alcance real: la red de la facultad,
  # porque ext_net es 192.168.3.0/24, no Internet.
  remote_ip_prefix = "0.0.0.0/0"
  description      = "HTTP publico hacia el load balancer"
}

# ---------------------------------------------------------------------------
# sg_app -- solo desde el load balancer
# ---------------------------------------------------------------------------

resource "openstack_networking_secgroup_rule_v2" "app_http_from_fe" {
  security_group_id = openstack_networking_secgroup_v2.app.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 80
  port_range_max    = 80

  # Puerto 80 y no 3000, siguiendo el diagrama de la cátedra al pie de la
  # letra. Metabase escucha en 3000 y no puede bindear un puerto privilegiado
  # sin correr como root; el desfasaje lo resuelve un nginx local en la VM app
  # que escucha en 80 y hace proxy_pass a 127.0.0.1:3000.
  # Ver cloud-init/app.yaml.
  remote_group_id = openstack_networking_secgroup_v2.fe.id
  description     = "HTTP solo desde el load balancer"
}

# ---------------------------------------------------------------------------
# sg_db -- solo desde la aplicación
# ---------------------------------------------------------------------------

resource "openstack_networking_secgroup_rule_v2" "db_mysql_from_app" {
  security_group_id = openstack_networking_secgroup_v2.db.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 3306
  port_range_max    = 3306

  # Ni el load balancer ni el bastion pueden llegar al 3306. Solo la app.
  # Este es el eslabón que se demuestra en la verificación: un mysql-client
  # desde el LB tiene que fallar por timeout.
  remote_group_id = openstack_networking_secgroup_v2.app.id
  description     = "MySQL solo desde la capa de aplicacion"
}

# ---------------------------------------------------------------------------
# sg_bastion -- el plano de gestión
# ---------------------------------------------------------------------------

resource "openstack_networking_secgroup_rule_v2" "bastion_ssh_from_admin" {
  security_group_id = openstack_networking_secgroup_v2.bastion.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22

  # Ver la justificación de 0.0.0.0/0 en variables.tf.
  # Candidato a cerrarse a la /24 de ZeroTier una vez confirmada la IP de
  # origen real en los logs de sshd.
  remote_ip_prefix = var.ssh_allowed_cidr
  description      = "SSH de administracion hacia el bastion"
}

# ---------------------------------------------------------------------------
# SSH hacia las tres capas internas: SOLO desde el bastion.
#
# Se usa for_each en vez de tres bloques repetidos: la regla es idéntica, lo
# único que cambia es el grupo destino. Si mañana hay que tocarla, se toca en
# un solo lugar.
# ---------------------------------------------------------------------------

locals {
  # Capas internas que reciben SSH desde el bastion.
  # El bastion NO está acá: no se administra a sí mismo desde sí mismo.
  internal_layers = {
    fe  = openstack_networking_secgroup_v2.fe.id
    app = openstack_networking_secgroup_v2.app.id
    db  = openstack_networking_secgroup_v2.db.id
  }
}

resource "openstack_networking_secgroup_rule_v2" "ssh_from_bastion" {
  for_each = local.internal_layers

  security_group_id = each.value
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22

  remote_group_id = openstack_networking_secgroup_v2.bastion.id
  description     = "SSH solo desde el bastion"
}

# ICMP desde el bastion hacia las capas internas.
#
# AMPLIACIÓN CONSCIENTE del diagrama: no está dibujado.
# Motivo: sin ping no se puede distinguir "la VM está caída" de "el puerto
# está cerrado" al diagnosticar. El origen sigue restringido a sg_bastion,
# así que no agrega superficie desde afuera.
resource "openstack_networking_secgroup_rule_v2" "icmp_from_bastion" {
  for_each = local.internal_layers

  security_group_id = each.value
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "icmp"

  remote_group_id = openstack_networking_secgroup_v2.bastion.id
  description     = "ICMP de diagnostico desde el bastion"
}
