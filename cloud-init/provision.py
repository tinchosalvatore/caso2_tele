#!/usr/bin/env python3
# ===========================================================================
# provision.py -- aprovisionamiento inicial de Metabase por su REST API.
#
# Corre DENTRO de la VM app, disparado por una unit systemd oneshot que
# espera a que Metabase este arriba. Es la capa de configuracion de la
# aplicacion: hace que la app sea CATTLE (reproducible desde cero) en vez de
# una mascota configurada a mano por la UI.
#
# Es ESTATICO (no pasa por templatefile): todos los valores llegan por
# variables de entorno desde /etc/metabase/provision.env. Asi los '$' de este
# archivo no chocan con la interpolacion de OpenTofu.
#
# Idempotente: si Metabase ya tiene admin (has-user-setup), no hace nada. El
# guard real es la API, no un archivo local -- porque la metadata vive en la
# db, que persiste aunque se recree la VM app.
# ===========================================================================
import json, os, sys, time, uuid, urllib.request, urllib.error

BASE = os.environ.get("MB_URL", "http://127.0.0.1:3000")


def api(method, path, data=None, session=None):
    """Llama a la API. Devuelve (status_code, cuerpo_parseado)."""
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(BASE + path, data=body, method=method)
    req.add_header("Content-Type", "application/json")
    if session:
        req.add_header("X-Metabase-Session", session)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            parsed = json.loads(raw)
        except Exception:
            parsed = {"raw": raw.decode(errors="replace")}
        return e.code, parsed


def wait_health(tries=60, delay=5):
    """Metabase tarda en migrar al primer arranque; espera hasta ~5 min."""
    for _ in range(tries):
        try:
            code, _ = api("GET", "/api/health")
            if code == 200:
                return True
        except Exception:
            pass
        time.sleep(delay)
    return False


def main():
    if not wait_health():
        sys.exit("Metabase no respondio /api/health a tiempo")

    _, props = api("GET", "/api/session/properties")
    if props.get("has-user-setup"):
        print("Metabase ya configurado (has-user-setup=true); nada que hacer.")
        return

    token = props.get("setup-token")
    if not token:
        sys.exit("Sin setup-token y sin setup previo: estado inesperado")

    # --- 1. Crear el usuario admin ------------------------------------------
    site = os.environ.get("MB_SITE_NAME", "Tele Metabase")
    code, res = api("POST", "/api/setup", {
        "token": token,
        "user": {
            "first_name": os.environ.get("MB_ADMIN_FIRST", "Admin"),
            "last_name":  os.environ.get("MB_ADMIN_LAST", "Tele"),
            "email":      os.environ["MB_ADMIN_EMAIL"],
            "password":   os.environ["MB_ADMIN_PASSWORD"],
            "site_name":  site,
        },
        "prefs": {"site_name": site, "allow_tracking": False},
        "database": None,   # el datasource se agrega aparte, mas abajo
    })
    if code not in (200, 201):
        sys.exit(f"POST /api/setup fallo: {code} {res}")
    session = res["id"] if isinstance(res, dict) else res

    # --- 2. Agregar la base mobility como fuente de datos -------------------
    # Se conecta con mobility_ro: solo SELECT. Metabase nunca escribe el dataset.
    code, db = api("POST", "/api/database", {
        "engine": "mysql",
        "name": "Mobility",
        "details": {
            "host": os.environ["DB_HOST"],
            "port": 3306,
            "dbname": os.environ.get("MOBILITY_DB", "mobility"),
            "user": "mobility_ro",
            "password": os.environ["MOBILITY_RO_PASS"],
            "ssl": False,
            "tunnel-enabled": False,
        },
    }, session=session)
    if code not in (200, 201):
        sys.exit(f"POST /api/database fallo: {code} {db}")
    db_id = db["id"]

    # Disparar sync del esquema (best-effort; la pregunta es SQL nativa y no
    # depende de que el sync haya terminado).
    api("POST", f"/api/database/{db_id}/sync_schema", session=session)

    # --- 3. Crear la pregunta SQL con 4 filtros + grafico de lineas ---------
    # 4 series (retail, grocery, parks, workplaces) sobre el eje temporal,
    # igual que la visualizacion del enunciado.
    sql = (
        "SELECT `date`,\n"
        "  retail_and_recreation_percent_change_from_baseline AS retail,\n"
        "  grocery_and_pharmacy_percent_change_from_baseline  AS grocery,\n"
        "  parks_percent_change_from_baseline                 AS parks,\n"
        "  workplaces_percent_change_from_baseline            AS workplaces\n"
        "FROM mobility\n"
        "WHERE sub_region_1 = {{sub_region_1}}\n"
        "  [[AND sub_region_2 = {{sub_region_2}}]]\n"
        "  [[AND `date` >= {{fecha_desde}}]]\n"
        "  [[AND `date` <= {{fecha_hasta}}]]\n"
        "ORDER BY `date`"
    )

    # Un id (uuid) por variable; el mismo id se referencia en parameters.
    ids = {k: str(uuid.uuid4()) for k in
           ("sub_region_1", "sub_region_2", "fecha_desde", "fecha_hasta")}

    template_tags = {
        "sub_region_1": {"id": ids["sub_region_1"], "name": "sub_region_1",
                         "display-name": "Sub region 1", "type": "text",
                         "required": True, "default": "Mendoza Province"},
        "sub_region_2": {"id": ids["sub_region_2"], "name": "sub_region_2",
                         "display-name": "Sub region 2", "type": "text"},
        "fecha_desde":  {"id": ids["fecha_desde"], "name": "fecha_desde",
                         "display-name": "Fecha desde", "type": "date"},
        "fecha_hasta":  {"id": ids["fecha_hasta"], "name": "fecha_hasta",
                         "display-name": "Fecha hasta", "type": "date"},
    }
    parameters = [
        {"id": ids["sub_region_1"], "type": "category", "name": "Sub region 1",
         "slug": "sub_region_1", "default": "Mendoza Province",
         "target": ["variable", ["template-tag", "sub_region_1"]]},
        {"id": ids["sub_region_2"], "type": "category", "name": "Sub region 2",
         "slug": "sub_region_2",
         "target": ["variable", ["template-tag", "sub_region_2"]]},
        {"id": ids["fecha_desde"], "type": "date/single", "name": "Fecha desde",
         "slug": "fecha_desde",
         "target": ["variable", ["template-tag", "fecha_desde"]]},
        {"id": ids["fecha_hasta"], "type": "date/single", "name": "Fecha hasta",
         "slug": "fecha_hasta",
         "target": ["variable", ["template-tag", "fecha_hasta"]]},
    ]

    code, card = api("POST", "/api/card", {
        "name": "Movilidad Google - variacion por categoria",
        "dataset_query": {
            "type": "native",
            "native": {"query": sql, "template-tags": template_tags},
            "database": db_id,
        },
        "display": "line",
        "visualization_settings": {
            "graph.dimensions": ["date"],
            "graph.metrics": ["retail", "grocery", "parks", "workplaces"],
        },
        "parameters": parameters,
    }, session=session)
    if code not in (200, 201):
        sys.exit(f"POST /api/card fallo: {code} {card}")

    print(f"Provisionado OK. datasource id={db_id}, card id={card.get('id')}")


if __name__ == "__main__":
    main()
