terraform {
  # Fijo la versión mínima del motor. Si alguien corre esto con una versión
  # anterior, falla de entrada en vez de fallar raro más adelante.
  required_version = ">= 1.6.0"

  required_providers {
    openstack = {
      # Provider de la comunidad OpenStack (NO es hashicorp/openstack).
      source = "terraform-provider-openstack/openstack"

      # ~> 3.0 = acepta 3.x pero NO salta a 4.0.
      # Un major nuevo puede traer breaking changes en los nombres de recursos:
      # no quiero que un init futuro me rompa un TP que ya defendí.
      version = "~> 3.0"
    }
  }
}

# El provider NO lleva credenciales.
# Se autentica solo, leyendo las variables OS_* que exporta el openrc.
# Ese es el motivo por el que este archivo puede ir a git sin riesgo.
provider "openstack" {}
