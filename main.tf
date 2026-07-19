# ---------------------------------------------------------------------------
# CAPA DE RED
#
# Topología:
#
#   Internet
#      |
#   [ ext_net ]  <- data: existe, no la gestiono
#      |
#   [ tele_router ]  <- resource: lo creo yo, hace NAT/DNAT
#      |
#   [ tele_subnet 10.20.0.0/24 ] -- [ tele_net ]
#      |
#   lb / app / db / bastion
#
# Las dos floating IPs se sacan de ext_net y el router las traduce a las IPs
# privadas de lb y bastion.
# ---------------------------------------------------------------------------

# DATA, no resource: ext_net es infraestructura del proveedor. No la creo ni la
# destruyo, solo necesito su ID para colgarle el gateway del router.
# Si esto fuera un `resource`, un `tofu destroy` intentaría borrar la red
# externa de toda la facultad.
data "openstack_networking_network_v2" "external" {
  name = var.external_network_name
}

# --- Red privada -----------------------------------------------------------

resource "openstack_networking_network_v2" "private" {
  name           = "${var.project_prefix}_net"
  admin_state_up = true
}

resource "openstack_networking_subnet_v2" "private" {
  name            = "${var.project_prefix}_subnet"
  network_id      = openstack_networking_network_v2.private.id
  cidr            = var.subnet_cidr
  ip_version      = 4
  dns_nameservers = var.dns_nameservers
}

# --- Router: la única salida a Internet ------------------------------------

resource "openstack_networking_router_v2" "main" {
  name           = "${var.project_prefix}_router"
  admin_state_up = true

  # Esto es lo que le faltaba a martins-router (external_gateway_info = None):
  # sin gateway externo no hay SNAT de salida ni floating IPs de entrada.
  external_network_id = data.openstack_networking_network_v2.external.id
}

# El router y la subnet existen por separado; esto los une.
# Crea el puerto 10.20.0.1 que es el default gateway de las VMs.
resource "openstack_networking_router_interface_v2" "main" {
  router_id = openstack_networking_router_v2.main.id
  subnet_id = openstack_networking_subnet_v2.private.id
}

# --- Floating IPs ----------------------------------------------------------
#
# Dos, a propósito, y con roles distintos:
#   - lb:      plano de DATOS. Es la URL que usan los clientes de Metabase.
#   - bastion: plano de GESTIÓN. Es por donde entramos a operar.
#
# Separarlas permite que mañana se cierre el SSH al mundo sin tocar el
# servicio, y viceversa. Si fueran la misma IP, gestión y servicio quedarían
# acoplados.
#
# Se reservan acá (no en compute.tf) porque son un recurso de RED: existen en
# ext_net aunque todavía no haya ninguna VM a la cual asociarlas.

resource "openstack_networking_floatingip_v2" "lb" {
  pool        = var.external_network_name
  description = "Entrada publica HTTP al load balancer"
}

resource "openstack_networking_floatingip_v2" "bastion" {
  pool        = var.external_network_name
  description = "Entrada SSH de administracion"
}
