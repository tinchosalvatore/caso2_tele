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
#
# ext_net cumple UNA sola función acá: SALIDA (SNAT) para que app y db puedan
# hacer apt y bajar el JAR de Metabase.
# NO sirve para entrar. Se verificó empíricamente:
#   - floating IP -> TCP filtrado, incluso desde dentro de la nube
#   - puerto directo -> 403 "Tenant not allowed to create port on this network"
# La entrada va por net_umstack (ver abajo).
data "openstack_networking_network_v2" "external" {
  name = var.external_network_name
}

# Red compartida de la facultad. Es la "red externa" del diagrama (recuadro
# verde): la única alcanzable de verdad desde ZeroTier / el campus.
# También es `data`: existe y es de la cátedra, no la gestionamos.
data "openstack_networking_network_v2" "access" {
  name = var.access_network_name
}

# NOTA: se intentó fijar solo la subnet IPv4 en los puertos de acceso, para
# que las VMs no tomaran una IPv6 global. La política del tenant lo prohíbe
# (403 sobre create_port:fixed_ips:subnet_id), así que los puertos toman v4+v6
# y la protección queda enteramente a cargo del security group.
# Ver el comentario largo en compute.tf.

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

# --- Sobre las floating IPs (eliminadas a propósito) -----------------------
#
# El diseño original reservaba dos floating IPs en ext_net, una para el LB
# (plano de datos) y otra para el bastion (plano de gestión).
# Se descartaron tras verificar que en UMCloud no son alcanzables por TCP.
#
# La entrada al sistema se resuelve dando a lb y bastion una segunda placa de
# red en net_umstack (ver compute.tf). La separación datos/gestión se mantiene:
# son dos VMs distintas, con dos security groups distintos.
