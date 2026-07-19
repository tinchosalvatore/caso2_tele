# scripts/

Scripts de operación que se ejecutan **desde la notebook**, no dentro de las
VMs. Operan sobre la infraestructura ya desplegada; no la declaran.

| Archivo | Qué hace |
|---|---|
| `load_dataset.sh` | copia el dump de Google Mobility al `db` saltando por el bastión (`scp -J`) y lo carga en el schema `mobility` |

Las IPs no se hardcodean: salen de `tofu output`.
Requiere ZeroTier levantado (las VMs viven en la red de la facultad).
