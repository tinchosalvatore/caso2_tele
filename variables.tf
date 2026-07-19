# ---------------------------------------------------------------------------
# Variables del entorno UMCloud.
# Los defaults NO son inventados: salen de correr `openstack ... list` contra
# el tenant real. Si el TP se corre en otro tenant, se sobreescriben por tfvars.
# ---------------------------------------------------------------------------

variable "project_prefix" {
  description = "Prefijo de todos los recursos, para distinguirlos de infra ajena en el tenant compartido."
  type        = string
  default     = "tele"
}

# --- Red -------------------------------------------------------------------

variable "external_network_name" {
  description = <<-EOT
    Red de SALIDA. El router le cuelga el gateway y hace SNAT: es lo que
    permite que las VMs de la red privada hagan apt y bajen el JAR de Metabase.
    NO se usa para entrar: se verificó que no acepta floating IPs alcanzables
    ni permite crear puertos al tenant.
  EOT
  type        = string
  default     = "ext_net"
}

variable "access_network_name" {
  description = <<-EOT
    Red de ENTRADA: la red compartida de la cátedra, y la "red externa" del
    diagrama (recuadro verde).
    Es la única alcanzable desde ZeroTier / el campus, y donde el tenant sí
    puede crear puertos. Solo lb y bastion se cuelgan acá; app y db quedan
    exclusivamente en la red privada.
  EOT
  type        = string
  default     = "net_umstack"
}

variable "subnet_cidr" {
  description = <<-EOT
    CIDR de la red privada.
    Elegido para NO solaparse con lo que ya existe en el tenant:
      - 10.201.0.0/16 -> net_umstack (red compartida de la cátedra)
      - 172.19.0.0/24 -> martins-net (red previa, ajena a este TP)
    Un solapamiento haría que el router no sepa a dónde rutear.
  EOT
  type        = string
  default     = "10.20.0.0/24"
}

variable "dns_nameservers" {
  description = <<-EOT
    DNS de la subnet. Copiados de subnet_umstack, que es la que se sabe que
    funciona en UMCloud.
    Sin esto cloud-init no resuelve nombres: no hay apt, no hay descarga del
    JAR de Metabase, y las VMs bootean vacías. martins-subnet lo tiene vacío.
  EOT
  type        = list(string)
  default     = ["8.8.8.8", "1.1.1.1"]
}

# --- Compute ---------------------------------------------------------------

variable "image_name" {
  description = <<-EOT
    Imagen base. Se usa Ubuntu pelada a propósito, NO las golden images del
    tenant (srv-mysql-*, srv-nginx-*): la instalación y configuración se hace
    por cloud-init, que es la capa que el TP tiene que mostrar.
  EOT
  type        = string
  default     = "ubuntu_2404"
}

variable "keypair_name" {
  description = "Keypair ya existente en el tenant. La clave privada vive en la notebook, nunca en el repo."
  type        = string
  default     = "openstack_um_cloud"
}

variable "flavors" {
  description = <<-EOT
    Flavor por rol. Cada uno dimensionado por lo que corre adentro:
      lb / bastion -> m1.xsmall (1 GB): nginx y sshd casi no consumen.
      db           -> m1.small  (2 GB): MySQL con un dataset chico.
      app          -> m1.medium (4 GB): es una JVM. Con 2 GB Metabase arranca
                      al límite y muere por OOM al correr queries.
    Total: 5 vCPU / 8 GB, holgado contra la quota (25 cores / 64 GB).
  EOT
  type        = map(string)
  default = {
    lb      = "m1.xsmall"
    app     = "m1.medium"
    db      = "m1.small"
    bastion = "m1.xsmall"
  }
}

# --- Base de datos ---------------------------------------------------------

# root de MySQL NO tiene password: queda con auth_socket (solo se entra por
# socket local, siendo root del SO). No hay credencial de red de root que robar,
# y la carga del dataset via `sudo mysql` funciona por ese mismo socket.

variable "db_metabase_password" {
  description = "Password del usuario metabase_app (metadata de Metabase). Se pasa por TF_VAR_, nunca por archivo."
  type        = string
  sensitive   = true
}

variable "db_mobility_ro_password" {
  description = "Password del usuario mobility_ro (solo SELECT sobre el dataset)."
  type        = string
  sensitive   = true
}

variable "metabase_version" {
  description = <<-EOT
    Version de Metabase a descargar. "latest" baja la mas nueva; se puede fijar
    a una version concreta (ej: "v0.50.8") para que cada apply instale el mismo
    artefacto -- reproducibilidad, que es el sentido de IaC.
    La URL de descarga directa es downloads.metabase.com/<version>/metabase.jar
    (NO metabase.com/start/oss/jar, que es una pagina HTML, no el binario).
  EOT
  type        = string
  default     = "latest"
}

variable "metabase_db_name" {
  description = "Schema de metadata interna de Metabase (usuarios, preguntas, dashboards)."
  type        = string
  default     = "metabaseappdb"
}

variable "mobility_db_name" {
  description = "Schema del dataset de Google Mobility. Separado del anterior: son datos de distinta naturaleza y con distintos permisos."
  type        = string
  default     = "mobility"
}

# --- Acceso ----------------------------------------------------------------

variable "ssh_allowed_cidr" {
  description = <<-EOT
    Origen permitido para SSH contra el BASTION únicamente.
    Se deja en 0.0.0.0/0 porque el día de la defensa no se sabe desde qué IP
    se conecta uno. Es una decisión consciente, no un descuido: el bastion es
    el ÚNICO host con SSH abierto al mundo; las otras tres capas solo aceptan
    SSH desde sg_bastion.
  EOT
  type        = string
  default     = "0.0.0.0/0"
}
