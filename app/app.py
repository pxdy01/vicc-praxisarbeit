"""
VICC Praxisarbeit - Pendenzen- und Störungsverwaltung Schul-IT (Flask + PostgreSQL)

Endpunkte:
  GET    /              Oberfläche (HTML): Erfassung, Filter, Auswertung
  GET    /health        DB-Konnektivitätscheck (200 / 503)
  GET    /stats         Kennzahlen nach Status und Kategorie (JSON)
  GET    /tasks         alle Meldungen
  POST   /tasks         Meldung anlegen    {"title": str, "category"?, "priority"?, "status"?, "reporter"?}
  GET    /tasks/<id>    einzelne Meldung
  PUT    /tasks/<id>    Meldung aktualisieren
  DELETE /tasks/<id>    Meldung löschen
  POST   /ui/meldungen                  Formular: Meldung anlegen -> Redirect auf /
  POST   /ui/meldungen/<id>/status      Formular: Status weiterschalten -> Redirect auf /
  POST   /ui/meldungen/<id>/loeschen    Formular: Meldung löschen -> Redirect auf /

Konfiguration ausschliesslich über Umgebungsvariablen:
  DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD, DB_SSLMODE
"""

import html
import logging
import os
from contextlib import contextmanager

import psycopg2
import psycopg2.extras
from flask import Flask, jsonify, redirect, request

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("vicc-api")

APP_VERSION = os.getenv("APP_VERSION", "3.0.0")

# Erlaubte Werte; zentral definiert, weil sie in Validierung, Formular und Statuswechsel gebraucht werden.
KATEGORIEN = ["Netzwerk", "Hardware", "Software", "Konto", "Sonstiges"]
PRIORITAETEN = ["hoch", "mittel", "tief"]
STATUS_WERTE = ["offen", "in Arbeit", "erledigt"]
STATUS_FOLGE = {"offen": "in Arbeit", "in Arbeit": "erledigt", "erledigt": "offen"}

DB_CONFIG = {
    "host": os.getenv("DB_HOST", "localhost"),
    "port": int(os.getenv("DB_PORT", "5432")),
    "dbname": os.getenv("DB_NAME", "tasks"),
    "user": os.getenv("DB_USER", "postgres"),
    "password": os.getenv("DB_PASSWORD", ""),
    "sslmode": os.getenv("DB_SSLMODE", "require"),
    "connect_timeout": int(os.getenv("DB_CONNECT_TIMEOUT", "5")),
}

app = Flask(__name__)
app.json.sort_keys = False
app.json.ensure_ascii = False

_schema_ready = False


@contextmanager
def get_conn():
    """Kurzlebige Verbindung pro Request; Commit bei Erfolg, Rollback bei Fehler."""
    conn = psycopg2.connect(**DB_CONFIG)
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def ensure_schema():
    """Legt die Tabelle beim ersten DB-Zugriff an und ergänzt neue Spalten (idempotent)."""
    global _schema_ready
    if _schema_ready:
        return
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS tasks (
                id         SERIAL PRIMARY KEY,
                title      VARCHAR(200) NOT NULL,
                done       BOOLEAN      NOT NULL DEFAULT FALSE,
                created_at TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
                updated_at TIMESTAMPTZ  NOT NULL DEFAULT NOW()
            )
            """
        )
        # Erweiterung 3.0.0: zusätzliche Felder, auch für bestehende Tabellen
        for ddl in (
            "ALTER TABLE tasks ADD COLUMN IF NOT EXISTS category VARCHAR(20) NOT NULL DEFAULT 'Sonstiges'",
            "ALTER TABLE tasks ADD COLUMN IF NOT EXISTS priority VARCHAR(10) NOT NULL DEFAULT 'mittel'",
            "ALTER TABLE tasks ADD COLUMN IF NOT EXISTS status   VARCHAR(12) NOT NULL DEFAULT 'offen'",
            "ALTER TABLE tasks ADD COLUMN IF NOT EXISTS reporter VARCHAR(60) NOT NULL DEFAULT '-'",
        ):
            cur.execute(ddl)
    _schema_ready = True
    log.info("Schema bereit")


def row_to_dict(row):
    return {
        "id": row["id"],
        "title": row["title"],
        "category": row["category"],
        "priority": row["priority"],
        "status": row["status"],
        "reporter": row["reporter"],
        "done": row["done"],
        "created_at": row["created_at"].isoformat(),
        "updated_at": row["updated_at"].isoformat(),
    }


# Offene Meldungen zuoberst, innerhalb davon nach Priorität
SORTIERUNG = """
    ORDER BY CASE status WHEN 'offen' THEN 1 WHEN 'in Arbeit' THEN 2 ELSE 3 END,
             CASE priority WHEN 'hoch' THEN 1 WHEN 'mittel' THEN 2 ELSE 3 END,
             id
"""


def fetch_all_tasks(status=None, priority=None):
    """Alle Meldungen, optional gefiltert nach Status und/oder Priorität."""
    ensure_schema()
    bedingungen, parameter = [], []
    if status in STATUS_WERTE:
        bedingungen.append("status = %s")
        parameter.append(status)
    if priority in PRIORITAETEN:
        bedingungen.append("priority = %s")
        parameter.append(priority)
    where = ("WHERE " + " AND ".join(bedingungen)) if bedingungen else ""
    with get_conn() as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(f"SELECT * FROM tasks {where} {SORTIERUNG}", parameter)
        return [row_to_dict(r) for r in cur.fetchall()]


def fetch_stats():
    """Kennzahlen nach Status und Kategorie."""
    ensure_schema()
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute("SELECT status, category, COUNT(*) FROM tasks GROUP BY status, category")
        zeilen = cur.fetchall()
    nach_status = {s: 0 for s in STATUS_WERTE}
    nach_kategorie = {k: 0 for k in KATEGORIEN}
    total = 0
    for status, kategorie, anzahl in zeilen:
        nach_status[status] = nach_status.get(status, 0) + anzahl
        nach_kategorie[kategorie] = nach_kategorie.get(kategorie, 0) + anzahl
        total += anzahl
    return {"total": total, "nach_status": nach_status, "nach_kategorie": nach_kategorie}


def validate_payload(data, partial):
    """Gibt (werte, fehlermeldung) zurück. partial=True erlaubt fehlende Felder (PUT)."""
    if not isinstance(data, dict):
        return None, "JSON-Objekt erwartet"
    values = {}
    if "title" in data:
        title = data["title"]
        if not isinstance(title, str) or not title.strip():
            return None, "'title' muss ein nicht-leerer String sein"
        if len(title) > 200:
            return None, "'title' darf max. 200 Zeichen lang sein"
        values["title"] = title.strip()
    elif not partial:
        return None, "'title' ist erforderlich"
    if "done" in data:
        if not isinstance(data["done"], bool):
            return None, "'done' muss true oder false sein"
        values["done"] = data["done"]
        # Rückwärtskompatibel: 'done' ohne 'status' setzt den Status passend mit
        if "status" not in data:
            values["status"] = "erledigt" if data["done"] else "offen"
    if "category" in data:
        if data["category"] not in KATEGORIEN:
            return None, f"'category' muss einer dieser Werte sein: {', '.join(KATEGORIEN)}"
        values["category"] = data["category"]
    if "priority" in data:
        if data["priority"] not in PRIORITAETEN:
            return None, f"'priority' muss einer dieser Werte sein: {', '.join(PRIORITAETEN)}"
        values["priority"] = data["priority"]
    if "status" in data:
        if data["status"] not in STATUS_WERTE:
            return None, f"'status' muss einer dieser Werte sein: {', '.join(STATUS_WERTE)}"
        values["status"] = data["status"]
        # Status und done konsistent halten (done bleibt für die bestehende API erhalten)
        values["done"] = data["status"] == "erledigt"
    if "reporter" in data:
        reporter = data["reporter"]
        if not isinstance(reporter, str) or len(reporter) > 60:
            return None, "'reporter' muss ein String mit max. 60 Zeichen sein"
        values["reporter"] = reporter.strip() or "-"
    if partial and not values:
        return None, "mindestens eines der Felder title, category, priority, status, reporter oder done angeben"
    return values, None


def insert_task(values):
    """Fügt eine Meldung ein. Spaltennamen stammen aus validate_payload (Whitelist)."""
    ensure_schema()
    values.setdefault("done", values.get("status", "offen") == "erledigt")
    spalten = list(values.keys())
    platzhalter = ", ".join(["%s"] * len(spalten))
    with get_conn() as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(
            f"INSERT INTO tasks ({', '.join(spalten)}) VALUES ({platzhalter}) RETURNING *",
            tuple(values.values()),
        )
        return row_to_dict(cur.fetchone())


# --------------------------------------------------------------------------- #
# Fehlerbehandlung: DB-Fehler -> 503, sonst JSON statt HTML-Fehlerseiten
# --------------------------------------------------------------------------- #
@app.errorhandler(psycopg2.OperationalError)
def db_unavailable(err):
    log.error("DB nicht erreichbar: %s", err)
    return jsonify(error="Datenbank nicht erreichbar"), 503


@app.errorhandler(404)
def not_found(_err):
    return jsonify(error="nicht gefunden"), 404


@app.errorhandler(405)
def method_not_allowed(_err):
    return jsonify(error="Methode nicht erlaubt"), 405


# --------------------------------------------------------------------------- #
# Oberfläche
# --------------------------------------------------------------------------- #
def optionen(werte, ausgewaehlt, leer_text=None):
    """Baut die <option>-Elemente eines Auswahlfeldes."""
    teile = []
    if leer_text is not None:
        sel = " selected" if not ausgewaehlt else ""
        teile.append(f'<option value=""{sel}>{html.escape(leer_text)}</option>')
    for wert in werte:
        sel = " selected" if wert == ausgewaehlt else ""
        teile.append(f'<option value="{html.escape(wert)}"{sel}>{html.escape(wert)}</option>')
    return "".join(teile)


@app.get("/")
def index():
    """Oberfläche mit Erfassungsformular, Filter, Auswertung und Liste."""
    filter_status = request.args.get("status", "")
    filter_prio = request.args.get("prio", "")
    try:
        tasks = fetch_all_tasks(filter_status or None, filter_prio or None)
        kennzahlen = fetch_stats()
        db_state = "verbunden"
    except psycopg2.Error:
        tasks, kennzahlen, db_state = [], {}, "NICHT erreichbar"

    nach_status = kennzahlen.get("nach_status", {})
    nach_kategorie = kennzahlen.get("nach_kategorie", {})
    kennzahl_text = " · ".join(
        [f"Total <strong>{kennzahlen.get('total', 0)}</strong>"]
        + [f"{html.escape(s)}: <strong>{nach_status.get(s, 0)}</strong>" for s in STATUS_WERTE]
    )
    kategorie_text = " · ".join(
        f"{html.escape(k)}: {nach_kategorie.get(k, 0)}" for k in KATEGORIEN if nach_kategorie.get(k, 0)
    ) or "noch keine Meldungen erfasst"

    rows = "".join(
        f"<tr class='p-{html.escape(t['priority'])}'>"
        f"<td>{t['id']}</td>"
        f"<td>{html.escape(t['title'])}</td>"
        f"<td>{html.escape(t['category'])}</td>"
        f"<td>{html.escape(t['priority'])}</td>"
        f"<td><span class='st st-{html.escape(t['status'].replace(' ', '-'))}'>{html.escape(t['status'])}</span></td>"
        f"<td>{html.escape(t['reporter'])}</td>"
        f"<td>{html.escape(t['created_at'][:16].replace('T', ' '))}</td>"
        f"<td class='akt'>"
        f"<form method='post' action='/ui/meldungen/{t['id']}/status'><button title='Status weiterschalten'>Status weiter</button></form>"
        f"<form method='post' action='/ui/meldungen/{t['id']}/loeschen'><button class='del'>Löschen</button></form>"
        f"</td></tr>"
        for t in tasks
    ) or "<tr><td colspan='8'>Keine Meldungen für diese Auswahl.</td></tr>"

    return f"""<!doctype html>
<html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Pendenzen- und Störungsverwaltung Schul-IT</title>
<style>
 body{{font-family:system-ui,sans-serif;max-width:1050px;margin:2rem auto;padding:0 1rem;color:#1f2937}}
 h1{{margin-bottom:.2rem}}
 .meta{{color:#4b5563;font-size:.9rem;margin-top:0}}
 .box{{border:1px solid #d1d5db;border-radius:6px;padding:.8rem 1rem;margin:1rem 0;background:#f9fafb}}
 .kpi{{font-size:1.05rem}}
 .kpi .sub{{display:block;color:#4b5563;font-size:.85rem;margin-top:.3rem}}
 form.inline{{display:flex;flex-wrap:wrap;gap:.5rem;align-items:flex-end}}
 label{{display:flex;flex-direction:column;font-size:.85rem;color:#374151}}
 input,select{{padding:.35rem;border:1px solid #9ca3af;border-radius:4px;font-size:.95rem}}
 button{{padding:.35rem .7rem;border:1px solid #9ca3af;border-radius:4px;background:#fff;cursor:pointer;font-size:.85rem}}
 button:hover{{background:#eef2ff}}
 button.del{{color:#b91c1c}}
 table{{border-collapse:collapse;width:100%;margin-top:.5rem}}
 td,th{{border:1px solid #d1d5db;padding:.4rem;text-align:left;font-size:.92rem;vertical-align:middle}}
 th{{background:#eef2f7}}
 td.akt{{display:flex;gap:.3rem}}
 tr.p-hoch td:nth-child(4){{color:#b91c1c;font-weight:bold}}
 .st{{padding:.1rem .45rem;border-radius:10px;font-size:.82rem;border:1px solid #9ca3af}}
 .st-offen{{background:#fee2e2;border-color:#ef4444}}
 .st-in-Arbeit{{background:#fef3c7;border-color:#f59e0b}}
 .st-erledigt{{background:#dcfce7;border-color:#22c55e}}
 code{{background:#f2f2f2;padding:.1rem .3rem}}
</style></head><body>
<h1>Pendenzen- und Störungsverwaltung Schul-IT</h1>
<p class="meta">Version <code>{APP_VERSION}</code> · Host <code>{html.escape(os.getenv("HOSTNAME", "-"))}</code>
 · Datenbank: <strong>{db_state}</strong> · API: <a href="/health">/health</a> · <a href="/tasks">/tasks</a> · <a href="/stats">/stats</a></p>

<div class="box kpi">{kennzahl_text}<span class="sub">nach Kategorie: {kategorie_text}</span></div>

<div class="box">
  <strong>Neue Meldung erfassen</strong>
  <form class="inline" method="post" action="/ui/meldungen" style="margin-top:.6rem">
    <label>Titel<input name="title" required maxlength="200" size="34" placeholder="z. B. Drucker Sekretariat offline"></label>
    <label>Kategorie<select name="category">{optionen(KATEGORIEN, "Sonstiges")}</select></label>
    <label>Priorität<select name="priority">{optionen(PRIORITAETEN, "mittel")}</select></label>
    <label>Status<select name="status">{optionen(STATUS_WERTE, "offen")}</select></label>
    <label>Melder<input name="reporter" maxlength="60" size="16" placeholder="z. B. Sekretariat"></label>
    <button type="submit">Meldung erfassen</button>
  </form>
</div>

<div class="box">
  <strong>Filter</strong>
  <form class="inline" method="get" action="/" style="margin-top:.6rem">
    <label>Status<select name="status">{optionen(STATUS_WERTE, filter_status, "alle")}</select></label>
    <label>Priorität<select name="prio">{optionen(PRIORITAETEN, filter_prio, "alle")}</select></label>
    <button type="submit">Filtern</button>
  </form>
</div>

<table>
<tr><th>ID</th><th>Titel</th><th>Kategorie</th><th>Priorität</th><th>Status</th><th>Melder</th><th>Erfasst (UTC)</th><th>Aktion</th></tr>
{rows}
</table>
</body></html>"""


# --------------------------------------------------------------------------- #
# API-Routen
# --------------------------------------------------------------------------- #
@app.get("/health")
def health():
    """Echter Konnektivitätscheck gegen PostgreSQL."""
    try:
        with get_conn() as conn, conn.cursor() as cur:
            cur.execute("SHOW server_version")
            version = cur.fetchone()[0]
        return jsonify(status="ok", database="reachable", db_version=version, app_version=APP_VERSION), 200
    except psycopg2.Error as err:
        log.warning("Health-Check fehlgeschlagen: %s", err)
        return jsonify(status="error", database="unreachable", app_version=APP_VERSION), 503


@app.get("/stats")
def stats():
    """Kennzahlen nach Status und Kategorie."""
    return jsonify(fetch_stats())


@app.get("/tasks")
def list_tasks():
    return jsonify(fetch_all_tasks(request.args.get("status"), request.args.get("prio")))


@app.post("/tasks")
def create_task():
    values, err = validate_payload(request.get_json(silent=True), partial=False)
    if err:
        return jsonify(error=err), 400
    task = insert_task(values)
    return jsonify(task), 201, {"Location": f"/tasks/{task['id']}"}


@app.get("/tasks/<int:task_id>")
def get_task(task_id):
    ensure_schema()
    with get_conn() as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute("SELECT * FROM tasks WHERE id = %s", (task_id,))
        row = cur.fetchone()
    if row is None:
        return jsonify(error=f"Task {task_id} nicht gefunden"), 404
    return jsonify(row_to_dict(row))


def update_task_fields(task_id, values):
    """Aktualisiert die übergebenen Felder. Spaltennamen aus validate_payload (Whitelist)."""
    ensure_schema()
    assignments = ", ".join(f"{col} = %s" for col in values)
    with get_conn() as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(
            f"UPDATE tasks SET {assignments}, updated_at = NOW() WHERE id = %s RETURNING *",
            (*values.values(), task_id),
        )
        return cur.fetchone()


@app.put("/tasks/<int:task_id>")
def update_task(task_id):
    values, err = validate_payload(request.get_json(silent=True), partial=True)
    if err:
        return jsonify(error=err), 400
    row = update_task_fields(task_id, values)
    if row is None:
        return jsonify(error=f"Task {task_id} nicht gefunden"), 404
    return jsonify(row_to_dict(row))


@app.delete("/tasks/<int:task_id>")
def delete_task(task_id):
    ensure_schema()
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute("DELETE FROM tasks WHERE id = %s", (task_id,))
        deleted = cur.rowcount
    if not deleted:
        return jsonify(error=f"Task {task_id} nicht gefunden"), 404
    return "", 204


# --------------------------------------------------------------------------- #
# Formular-Routen der Oberfläche (Post/Redirect/Get)
# --------------------------------------------------------------------------- #
@app.post("/ui/meldungen")
def ui_create():
    daten = {
        "title": request.form.get("title", ""),
        "category": request.form.get("category", "Sonstiges"),
        "priority": request.form.get("priority", "mittel"),
        "status": request.form.get("status", "offen"),
        "reporter": request.form.get("reporter", "") or "-",
    }
    values, err = validate_payload(daten, partial=False)
    if err:
        log.warning("Formulareingabe abgelehnt: %s", err)
        return redirect("/", code=303)
    insert_task(values)
    return redirect("/", code=303)


@app.post("/ui/meldungen/<int:task_id>/status")
def ui_status(task_id):
    ensure_schema()
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute("SELECT status FROM tasks WHERE id = %s", (task_id,))
        row = cur.fetchone()
    if row is None:
        return redirect("/", code=303)
    neuer_status = STATUS_FOLGE.get(row[0], "offen")
    update_task_fields(task_id, {"status": neuer_status, "done": neuer_status == "erledigt"})
    return redirect("/", code=303)


@app.post("/ui/meldungen/<int:task_id>/loeschen")
def ui_delete(task_id):
    ensure_schema()
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute("DELETE FROM tasks WHERE id = %s", (task_id,))
    return redirect("/", code=303)


if __name__ == "__main__":
    # Nur für lokale Entwicklung; im Container startet gunicorn.
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "8000")))
