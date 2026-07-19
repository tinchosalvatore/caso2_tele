# cloud-init/

Manifiestos `#cloud-config` (uno por rol). Cada uno se inyecta como `user_data`
de su VM en `compute.tf` y lo ejecuta **cloud-init dentro de la VM, una sola
vez, al primer arranque**.

Es la capa de CONFIGURACIÓN, distinta de la de infraestructura: acá se instala
y configura el software, no se declaran recursos de la nube.

| Archivo | Rol | Qué instala/configura |
|---|---|---|
| `db.yaml` | base de datos | MySQL, schemas `metabaseappdb` y `mobility`, usuarios y grants |
| `app.yaml` | aplicación | JRE, Metabase (JAR + systemd), nginx local `:80 → :3000` |
| `lb.yaml` | load balancer | nginx reverse proxy hacia la app |
| `bastion.yaml` | bastión | cliente mysql para diagnóstico; netplan de la doble ruta |

Los valores que dependen de otra VM (IP de la DB, passwords) no están escritos a
mano: se inyectan con `templatefile()` desde `compute.tf`.
