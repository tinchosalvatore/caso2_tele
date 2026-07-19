#!/usr/bin/env bash
# ===========================================================================
# load_dataset.sh -- carga el dataset de Google Mobility en MySQL.
#
# Se corre DESDE LA NOTEBOOK, no dentro de las VMs. Opera sobre la infra ya
# desplegada; no la declara. Requiere ZeroTier levantado.
#
# Camino de los datos:
#   notebook --scp(-J bastion)--> db:/tmp --zcat|mysql--> schema mobility
#
# La carga la hace root por socket local en la db (operacion administrativa,
# una sola vez). El consumo en runtime lo hace mobility_ro (solo SELECT).
# Quien puebla no es quien lee.
# ===========================================================================
set -euo pipefail

# --- Parametros (con defaults) ---------------------------------------------
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519_openstackUM}"
DATASET="${DATASET:-data/google-mobility.sql.gz}"
SSH_USER="${SSH_USER:-ubuntu}"
REMOTE_TMP="/tmp/google-mobility.sql.gz"

# Ubicarse en la raiz del repo (el script puede invocarse desde cualquier lado).
cd "$(dirname "$0")/.."

# --- Chequeos previos ------------------------------------------------------
[ -f "$DATASET" ]  || { echo "ERROR: no existe el dataset: $DATASET" >&2; exit 1; }
[ -f "$SSH_KEY" ]  || { echo "ERROR: no existe la clave SSH: $SSH_KEY" >&2; exit 1; }
command -v tofu >/dev/null || { echo "ERROR: falta tofu en el PATH" >&2; exit 1; }

# --- Resolver IPs desde el estado (NO hardcodear) --------------------------
BASTION="$(tofu output -raw bastion_access_ip)"
DB="$(tofu output -json private_ips | python3 -c 'import json,sys; print(json.load(sys.stdin)["db"])')"
MOBILITY_DB="$(tofu output -raw mobility_db_name 2>/dev/null || echo mobility)"

echo ">> bastion=$BASTION  db=$DB  schema=$MOBILITY_DB"

# Opciones SSH comunes.
# StrictHostKeyChecking=no + UserKnownHostsFile=/dev/null: NO se fijan las host
# keys. Estas VMs son cattle: su host key cambia en cada recreacion, asi que
# fijarla daria falsos "MITM" en cada apply. El canal ya esta acotado por
# ZeroTier + los security groups. (accept-new no sirve: no se propaga al primer
# salto del ProxyJump y ademas igual chocaria al recrear.)
SSH_OPTS=(-i "$SSH_KEY"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=15)

# Salto por el bastion como ProxyCommand explicito, para que las MISMAS opciones
# apliquen al primer hop (el -o ProxyJump no las propaga bien).
JUMP=(-o "ProxyCommand=ssh ${SSH_OPTS[*]} -W %h:%p $SSH_USER@$BASTION")

# --- 1. Copiar el dump a la db (a traves del bastion) ----------------------
echo ">> copiando $DATASET -> db:$REMOTE_TMP (via bastion)"
scp "${SSH_OPTS[@]}" "${JUMP[@]}" "$DATASET" "$SSH_USER@$DB:$REMOTE_TMP"

# --- 2. Descomprimir y cargar; limpiar el /tmp de la db --------------------
# El dump no trae USE/CREATE DATABASE, asi que se canaliza directo al schema
# mobility. Trae DROP TABLE IF EXISTS, o sea que recargar es idempotente.
# root entra por socket local (sudo), sin password de red.
echo ">> cargando en MySQL (schema $MOBILITY_DB)"
ssh "${SSH_OPTS[@]}" "${JUMP[@]}" "$SSH_USER@$DB" \
  "zcat '$REMOTE_TMP' | sudo mysql '$MOBILITY_DB' && rm -f '$REMOTE_TMP'"

# --- 3. Verificar ----------------------------------------------------------
echo ">> verificando"
ssh "${SSH_OPTS[@]}" "${JUMP[@]}" "$SSH_USER@$DB" \
  "sudo mysql -N -e \"
     SELECT CONCAT('filas: ', COUNT(*)) FROM ${MOBILITY_DB}.mobility;
     SELECT CONCAT('rango: ', MIN(date), ' .. ', MAX(date)) FROM ${MOBILITY_DB}.mobility;
     SELECT CONCAT('paises: ', COUNT(DISTINCT country_region)) FROM ${MOBILITY_DB}.mobility;
   \""

echo ">> OK: dataset cargado."
