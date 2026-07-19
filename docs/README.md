# Metabase multicapa en OpenStack (UMCloud) con OpenTofu

Despliegue reproducible de la plataforma de Business Intelligence **Metabase**
sobre la nube privada de la facultad (**UMCloud**, OpenStack), descrito
íntegramente como **infraestructura como código** con **OpenTofu**.

El objetivo del sistema es servir una visualización interactiva del dataset de
**Google Mobility** (variación de la movilidad ciudadana durante la pandemia),
con filtros por región y rango de fechas.

Todo lo que se ve aquí —las 4 máquinas virtuales, la red, los cortafuegos y hasta
la configuración interna de Metabase— se crea desde cero con un único
`tofu apply`. No hay pasos manuales de configuración, salvo la carga del dataset
(una operación de datos de una sola vez).

---

## 1. Qué es y qué hace

Es una aplicación web clásica de tres capas (front / aplicación / datos), más un
host de administración:

- **Load Balancer** (nginx): la única puerta pública. Expone el puerto 80 y
  reenvía el tráfico hacia la aplicación.
- **Aplicación** (Metabase): el servidor de BI. Genera los gráficos y sirve la
  interfaz web.
- **Base de datos** (MySQL): guarda dos cosas separadas — la configuración
  interna de Metabase y el dataset de Google Mobility.
- **Bastión**: el único punto de entrada por SSH a la red privada. Se usa para
  administrar y diagnosticar las otras máquinas.

El resultado final es una URL donde un usuario abre el navegador, elige una
provincia y un rango de fechas, y ve cómo cambió la movilidad (comercios,
parques, lugares de trabajo, etc.) respecto de la línea de base pre-pandemia.

---

## 2. Arquitectura

```
                        Vos (ZeroTier / campus)
                                  │
              ┌───────────────────┴───────────────────┐
              │   net_umstack  (10.201.0.0/16)         │  red de acceso
              │   "la red externa" del enunciado       │
              └──┬─────────────────────────────────┬───┘
             :80 │                              :22 │
          ┌──────▼──────┐                    ┌──────▼──────┐
          │     lb      │                    │   bastion   │
          │   (nginx)   │                    │    (ssh)    │
          └──────┬──────┘                    └──────┬──────┘
                 │                                  │
    ┌────────────┴──────────────────────────────────┴────────────┐
    │  tele_net  (10.20.0.0/24)   —   RED PRIVADA                 │
    │                                                             │
    │    ┌─────────┐   :80    ┌─────────┐   :3306   ┌─────────┐   │
    │    │   lb    ├─────────►│   app   ├──────────►│   db    │   │
    │    │         │          │Metabase │           │ MySQL   │   │
    │    │         │          │ :3000   │           │         │   │
    │    └─────────┘          └─────────┘           └─────────┘   │
    └───────────────────────────┬─────────────────────────────────┘
                                 │
                          ┌──────▼──────┐
                          │ tele_router │
                          └──────┬──────┘
                                 │ salida a Internet (apt, descargas)
                            ┌────▼────┐
                            │ ext_net │
                            └─────────┘
```

Puntos clave de la arquitectura:

- **`app` y `db` no tienen ninguna dirección accesible desde afuera.** Viven solo
  en la red privada. La única forma de tocarlas es a través del load balancer
  (para el servicio) o del bastión (para administrar). Ese es el corazón del
  diseño: cada capa habla únicamente con la adyacente.
- **`lb` y `bastion` tienen dos placas de red** (una en la red privada y otra en
  la de acceso). Son las únicas máquinas con un pie en cada mundo.
- **La entrada y la salida usan redes distintas.** Se entra por `net_umstack`; se
  sale a Internet por `ext_net` a través del router. En este tenant `ext_net` no
  admite publicar servicios, solo salida.

### Cadena de seguridad (los 4 cortafuegos)

Cada máquina tiene un *security group* que solo deja pasar lo estrictamente
necesario:

| Capa | Acepta | Desde |
|------|--------|-------|
| `sg_fe` (lb) | puerto 80 | cualquiera |
| `sg_app` (app) | puerto 80 | solo el load balancer |
| `sg_db` (db) | puerto 3306 | solo la aplicación |
| todas | puerto 22 (SSH) | solo el bastión |
| `sg_bastion` | puerto 22 (SSH) | cualquiera |

Si el load balancer intenta hablar directo con la base de datos, **falla**: no
está autorizado. Solo la aplicación puede. Esto se verifica automáticamente en el
despliegue.

---

## 3. Requisitos previos

Para operar este proyecto desde tu máquina necesitás tener configurado (se asume
que ya lo está):

- **OpenTofu** (`tofu`) instalado.
- **ZeroTier levantado**: sin la VPN no se llega a las máquinas. La API de
  OpenStack sí es pública, así que `tofu` funciona sin VPN, pero abrir Metabase o
  hacer SSH requiere ZeroTier conectado.
- **Cliente de OpenStack** (`openstack`) — opcional, útil para inspeccionar.
- **Archivo `openrc.sh`** en la raíz del repositorio: contiene las credenciales
  de OpenStack. Se activa con `source openrc.sh`. **No se versiona.**
- **Archivo `data/db-credentials.env`**: contiene las contraseñas de MySQL y del
  admin de Metabase. Se activa con `source data/db-credentials.env`. **No se
  versiona.**
- **Clave SSH** del keypair de UMCloud (por defecto
  `~/.ssh/id_ed25519_openstackUM`).

> Los archivos con credenciales y el estado de OpenTofu están excluidos de git
> por diseño. Ver `.gitignore`.

---

## 4. Cómo desplegarlo

Desde la raíz del repositorio:

```bash
# 1. Cargar credenciales de OpenStack y contraseñas en el entorno
source openrc.sh
source data/db-credentials.env

# 2. Inicializar (baja el provider de OpenStack). Solo la primera vez.
tofu init

# 3. Ver qué va a crear, sin tocar nada
tofu plan

# 4. Crear toda la infraestructura
tofu apply
```

El `apply` tarda unos minutos: crea la red y los cortafuegos, levanta las 4
máquinas, y cada una se autoconfigura al arrancar (instala su software y, en el
caso de la aplicación, descarga Metabase y lo deja configurado con el datasource
y la visualización ya creados).

Cuando termina, muestra los datos de acceso:

```bash
tofu output
```

```
bastion_access_ip = "10.201.x.x"
lb_access_ip      = "10.201.x.x"
metabase_url      = "http://10.201.x.x"
ssh_commands      = { ... comandos ssh listos para copiar ... }
```

> Las direcciones IP cambian en cada despliegue. Siempre consultalas con
> `tofu output`, no las memorices.

### Cargar el dataset (paso manual, una sola vez)

La infraestructura queda lista pero la base del dataset está vacía. Para poblarla:

```bash
scripts/load_dataset.sh
```

El script copia el dump de Google Mobility a la base de datos (a través del
bastión), lo carga y verifica. Toma las direcciones IP automáticamente de
`tofu output`.

### Destruir todo

```bash
tofu destroy
```

Elimina las 4 máquinas, la red y los cortafuegos. Solo afecta a lo que este
proyecto creó.

---

## 5. Cómo usarlo (nivel usuario)

### Abrir Metabase

Con ZeroTier levantado, abrí en el navegador la URL que da `tofu output`:

```
http://<lb_access_ip>
```

Ingresás con el usuario administrador:

- **Usuario:** `admin@tele.local`
- **Contraseña:** la del archivo `data/db-credentials.env`
  (variable `TF_VAR_metabase_admin_password`).

### La visualización

Ya está creada, se llama **"Movilidad Google - variacion por categoria"**. Es un
gráfico de líneas con cuatro series (comercios y farmacias, parques, lugares de
trabajo, comercio minorista y recreación) a lo largo del tiempo.

Tiene cuatro filtros arriba:

- **Sub region 1** — la provincia (ej: `Mendoza Province`).
- **Sub region 2** — el departamento (ej: `Capital Department`).
- **Fecha desde** / **Fecha hasta** — el rango temporal.

Cambiás los filtros y el gráfico se actualiza. Con `Mendoza Province` +
`Capital Department` reproduce la visualización del enunciado.

### Conectarse a las máquinas (administración)

Solo hace falta si querés inspeccionar o diagnosticar. La entrada es siempre por
el bastión:

```bash
# Entrar al bastión
ssh ubuntu@<bastion_access_ip>

# Entrar a una máquina interna saltando por el bastión (-J)
ssh -J ubuntu@<bastion_access_ip> ubuntu@<ip_privada_de_la_maquina>
```

`tofu output ssh_commands` te da estos comandos ya armados con las IP correctas.

---

## 6. Cómo viajan los datos por la aplicación

Es útil entender qué pasa cuando un usuario abre el gráfico. Se puede leer en dos
direcciones.

### Cuando pedís la página (de afuera hacia adentro)

1. **Tu navegador** pide `http://<lb_access_ip>`. Esa dirección es la placa
   pública del **load balancer**.
2. El **load balancer** (nginx) recibe el pedido en el puerto 80 y lo reenvía a
   la **aplicación**, también por el puerto 80, usando la red privada.
3. Dentro de la máquina de la aplicación, un nginx local recibe ese pedido en el
   puerto 80 y se lo pasa a **Metabase**, que escucha en el puerto 3000 solo en
   loopback (no es accesible desde la red: la única forma de llegar a él es este
   nginx local).
4. **Metabase** arma la respuesta. Si necesita datos del gráfico, consulta la
   **base de datos**.

### Cuando se genera el gráfico (la consulta de datos)

1. Metabase traduce los filtros que elegiste (provincia, fechas) en una consulta
   **SQL** contra la base de datos.
2. Se conecta a **MySQL** en el puerto 3306, dentro de la red privada, usando un
   usuario de **solo lectura** (`mobility_ro`). Ese usuario puede *leer* el
   dataset pero no modificarlo: quien carga los datos y quien los consulta son
   identidades distintas.
3. MySQL devuelve las filas del dataset de movilidad para esa provincia y ese
   rango de fechas.
4. Metabase transforma esas filas en las cuatro series del gráfico de líneas y te
   las manda de vuelta, recorriendo el camino inverso: Metabase → nginx local →
   load balancer → tu navegador.

### Por qué la base guarda dos cosas separadas

MySQL contiene dos "bases" (schemas) independientes:

- **`metabaseappdb`**: la memoria interna de Metabase (usuarios, preguntas
  guardadas, configuración). La escribe y lee Metabase con un usuario que tiene
  permisos completos sobre ella.
- **`mobility`**: el dataset de Google Mobility. Metabase solo lo *lee*, con el
  usuario de solo lectura.

Separarlas evita que una consulta al dataset pueda tocar la configuración de la
aplicación, y viceversa.

---

## 7. Estructura del repositorio

```
versions.tf        versión de OpenTofu y del provider
variables.tf       parámetros del entorno (red, imagen, flavors, credenciales)
main.tf            red privada, subred, router, redes externas (data sources)
security.tf        los 4 security groups y sus reglas
compute.tf         las 4 máquinas y sus placas de red
outputs.tf         IPs y comandos de acceso

cloud-init/        configuración interna de cada máquina (se ejecuta al arrancar)
  db.yaml            MySQL: schemas, usuarios, permisos
  app.yaml           Metabase (JAR + servicio) y nginx local
  lb.yaml            nginx reverse proxy
  bastion.yaml       cliente de diagnóstico y ruteo
  provision.py       configura Metabase por su API (admin, datasource, gráfico)

scripts/
  load_dataset.sh    carga el dataset de Google Mobility

data/
  google-mobility.sql.gz   el dataset (comprimido)

docs/
  PLAN.md            decisiones de diseño y justificación técnica
  README.md          este archivo
```

Para el detalle de **por qué** se tomó cada decisión de diseño (y los problemas
que se encontraron y resolvieron durante el desarrollo), ver `docs/PLAN.md`.
