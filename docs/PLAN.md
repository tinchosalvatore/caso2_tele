# Plan de resolución — Metabase multicapa en OpenStack

Trabajo práctico de Teleinformática (UM). Despliegue de la plataforma de BI
**Metabase** sobre **UMCloud** (OpenStack) usando **OpenTofu** como herramienta
de infraestructura como código, en el modelo **Cloud Classic** (IaaS: VMs,
redes y security groups como unidades de infraestructura).

---

## 1. Qué pide el enunciado

Dos entregables distintos:

1. **Infraestructura declarada en código**: 4 VMs (load balancer nginx,
   aplicación Metabase, base MySQL, bastión SSH), red privada con router, y 4
   security groups encadenados por referencia entre grupos.
2. **Demostración funcional**: cargar el dataset de Google Mobility en MySQL y
   reproducir en Metabase una visualización de líneas con filtros por
   `sub_region_1`, `sub_region_2` y rango de fechas.

El segundo punto no es IaC, pero condiciona el diseño del primero.

---

## 2. Arquitectura

```
                    ZeroTier / campus
                           │
              ┌────────────┴────────────┐
              │   net_umstack           │   red de ENTRADA
              │   10.201.0.0/16         │   (recuadro verde del diagrama)
              └──┬──────────────────┬───┘
                 │ :80              │ :22
            ┌────▼────┐       ┌─────▼─────┐
            │   lb    │       │  bastion  │   ← dual-homed
            │ (nginx) │       │   (ssh)   │
            └────┬────┘       └─────┬─────┘
                 │                  │
     ┌───────────┴──────────────────┴───────────┐
     │  tele_net  10.20.0.0/24                  │   red PRIVADA
     │                                          │   (recuadro rojo)
     │   ┌─────────┐  :3306   ┌──────────┐      │
     │   │   app   ├─────────►│    db    │      │
     │   │Metabase │          │  MySQL   │      │
     │   │  :3000  │          │          │      │
     │   └─────────┘          └──────────┘      │
     └───────────────────┬──────────────────────┘
                         │
                  ┌──────▼──────┐
                  │ tele_router │
                  └──────┬──────┘
                         │ SNAT (solo salida)
                     ┌───▼────┐
                     │ext_net │  apt, descarga del JAR
                     └────────┘
```

`app` y `db` **no tienen ninguna interfaz fuera de la red privada**. Esa es la
propiedad que hace que el bastión tenga sentido.

---

## 3. Cadena de confianza (security groups)

| Grupo | Ingress | Origen |
|---|---|---|
| `tele_sg_fe` | 80/tcp | `0.0.0.0/0` |
| | 22/tcp | `tele_sg_bastion` |
| `tele_sg_app` | 80/tcp | `tele_sg_fe` |
| | 22/tcp | `tele_sg_bastion` |
| `tele_sg_db` | 3306/tcp | `tele_sg_app` |
| | 22/tcp | `tele_sg_bastion` |
| `tele_sg_bastion` | 22/tcp | `0.0.0.0/0` |

**Decisión central:** las reglas se escriben con `remote_group_id`, nunca con la
IP privada de la VM vecina. Una IP cambia si la instancia se recrea; el grupo es
una identidad estable. Es lo que permite tratar a las VMs como *cattle* y no
como *pets*.

Agregados conscientes, no presentes en el diagrama original:
- **ICMP desde `sg_bastion`** hacia las tres capas, para poder distinguir "host
  caído" de "puerto cerrado" al diagnosticar.
- **Egress permisivo** (el default de OpenStack): sin salida no hay `apt` ni
  descarga del JAR de Metabase.

---

## 4. Decisiones de diseño y su justificación

| Decisión | Elegida | Por qué |
|---|---|---|
| Puerto de la app | nginx local en la VM app escucha `:80` y hace `proxy_pass` a `127.0.0.1:3000` | El diagrama especifica `:80` desde `sg_fe`. Metabase escucha en 3000 y no puede bindear un puerto privilegiado sin correr como root. Se cumple el enunciado sin modificarlo. |
| Entrada al sistema | Pata en `net_umstack` para `lb` y `bastion` | Verificado empíricamente que `ext_net` no admite ingress (ver §5). |
| Salida a Internet | Router con gateway a `ext_net` (SNAT) | El router no es para entrar, es para salir: sin él `app` y `db` no pueden instalar nada. |
| Base de datos | Un MySQL, dos schemas: `metabaseappdb` y `mobility` | Metabase necesita base propia para su metadata; H2 embebida no es persistente. Dos schemas = una sola VM que administrar. |
| Metabase | JAR + systemd | Cloud Classic es IaaS. Docker sería Cloud Native, otro modelo. |
| Imagen | `ubuntu_2404` pelada + cloud-init | Las golden images del tenant (`srv-mysql-*`, `srv-nginx-*`) esconderían la capa de configuración, que es parte del trabajo. |
| Estructura | Módulo plano, sin submódulos | 4 VMs no justifican la abstracción. |
| SGs en el puerto, no en la instancia | `openstack_networking_port_v2` | Nova (por nombre) y Neutron (por ID) se pisan si se usan las dos vías; produce diferencias fantasma en cada `plan`. |
| 4 bloques explícitos, no `for_each` | — | El LB necesita la IP de la app y la app la de la DB. `for_each` no expresa esas referencias cruzadas sin contorsiones. |

### Sobre `depends_on`

Se usa **una sola vez**, en las instancias, apuntando a
`openstack_networking_router_interface_v2`. Es el caso legítimo: las VMs
necesitan la ruta por default para que cloud-init pueda hacer `apt`, pero no
referencian al router interface por ningún atributo. Sin referencia no hay
arista en el grafo. `depends_on` es para dependencias **reales pero invisibles**
al grafo, no "por las dudas".

---

## 5. Hallazgos del entorno (corrección del plan original)

El plan inicial asumía el patrón estándar de OpenStack: floating IP sobre la red
externa como punto de entrada. **En UMCloud eso no funciona**, y se verificó con
dos pruebas independientes:

| Mecanismo de ingress por `ext_net` | Resultado |
|---|---|
| Floating IP (DNAT en el router) | TCP filtrado, incluso desde dentro de la nube |
| Puerto directo en `ext_net` | `403: Tenant not allowed to create port on this network` |

Conclusión: `ext_net` es exclusivamente el uplink de salida del tenant. La red
donde la cátedra permite publicar es `net_umstack`, que es además la única
alcanzable por ZeroTier. Coincide con el enunciado, cuyo screenshot muestra
`10.201.0.234:3000` — una dirección de `net_umstack`.

Las dos floating IPs reservadas inicialmente se eliminaron por no cumplir
ninguna función.

Otras restricciones encontradas:
- No se puede fijar la subnet de un puerto en `net_umstack`
  (`403 create_port:fixed_ips:subnet_id`). Los puertos toman IPv4 **e IPv6
  global**. La protección queda a cargo del security group: las reglas de
  OpenStack son allow-only sobre un default deny, y no se declaró ninguna regla
  IPv6, por lo que todo el ingress v6 está denegado. Verificado.
- Cuota de security groups: 10. Se usan 4.

---

## 6. Estructura de archivos

```
versions.tf     versión del motor y del provider (pineada)
variables.tf    parámetros del entorno; defaults tomados del tenant real
main.tf         red privada, subnet, router, data sources de las redes ajenas
security.tf     los 4 security groups y sus reglas
compute.tf      puertos e instancias
outputs.tf      IPs y comandos de acceso listos para copiar
cloud-init/     un manifiesto por rol (lb, app, db, bastion)
scripts/        carga del dataset
data/           dataset de Google Mobility
```

`security.tf` está separado a propósito: la cadena de confianza es el argumento
central del trabajo y tiene que poder leerse de corrido en un solo archivo.

---

## 7. Orden de trabajo

Se avanza por cortes, aplicando y verificando cada uno antes de seguir. Si se
mezclan infraestructura y configuración en un mismo paso, ante una falla no se
sabe cuál de las dos capas la causó.

1. ✅ Higiene del repositorio y descubrimiento del entorno
2. ✅ Capa de red
3. ✅ Security groups
4. ✅ Cómputo con cloud-init mínimo (verificación de boot y conectividad)
5. ✅ cloud-init reales: MySQL, Metabase + nginx local, nginx del LB, netplan
6. ✅ Carga del dataset de Google Mobility (scripts/load_dataset.sh)
7. ✅ Configuración de Metabase automatizada por su REST API (provision.py)

---

## 8. Verificación

Lo que importa no es que el servicio responda, sino que **el aislamiento
funcione**. Pruebas ejecutadas sobre el corte 4:

Matriz final, con toda la infraestructura desplegada:

| Prueba | Esperado | Resultado |
|---|---|---|
| **Positivos** | | |
| `http://<lb>/api/health` desde la notebook (LB→app→Metabase) | funciona | ✅ 200 |
| SSH al bastión desde ZeroTier | funciona | ✅ |
| SSH a `lb`/`app`/`db` con `ssh -J` por el bastión | funciona | ✅ |
| `app` → `db:3306` | funciona | ✅ |
| Metabase escribe su metadata en MySQL (no H2) | 175 tablas | ✅ |
| **Negativos** | | |
| `db:3306` directo desde afuera | debe fallar | ✅ bloqueado |
| `app:80` directo desde afuera | debe fallar | ✅ bloqueado |
| `lb` → `db:3306` (no es `sg_app`) | debe fallar | ✅ bloqueado |
| `app:3000` desde el LB (bind loopback) | debe fallar | ✅ bloqueado |
| SSH por la IPv6 global del bastión | debe fallar | ✅ cerrado |

### Bugs encontrados y resueltos (material de defensa)

- **MySQL escuchaba en localhost pese al `.cnf`.** Los archivos de `conf.d/` se
  leen alfabéticamente y el último gana; `99-tele.cnf` ordena *antes* que
  `mysqld.cnf`. Se renombró a `zz-tele.cnf`. Detectado con `ss`, no asumido.
- **JAR de Metabase corrupto.** `metabase.com/start/oss/jar` es una página HTML;
  `curl -f` la aceptó (HTTP 200). Se cambió a la URL de descarga directa y se
  agregó verificación de bytes mágicos `PK`. El `Restart=always` dejó el error
  repetido en `journalctl`, que fue lo que permitió diagnosticarlo.
- **Doble ruta por default en las VMs dual-homed.** Se resolvió con un netplan
  que sube la métrica del default de la placa privada a 300; la de acceso (100)
  gana de forma determinística.
- **`Failed to allocate the network(s)` al recrear el LB.** Error transitorio de
  Nova al reusar un puerto persistido; se resolvió reaplicando (tofu marcó la
  instancia como `tainted` y la recreó).

---

## 9. Manejo de credenciales

- Las credenciales de OpenStack se pasan por variables de entorno (`openrc`).
  Nunca aparecen en los `.tf`.
- Las passwords de MySQL se pasan por `TF_VAR_*` desde un archivo de entorno
  fuera de control de versiones.
- El `.tfstate` **guarda todos los valores en claro**, incluidos los marcados
  como `sensitive`. `sensitive` solo evita que se impriman en la salida de
  `plan` y `apply`; no cifra nada. Por eso el state está excluido de git.
