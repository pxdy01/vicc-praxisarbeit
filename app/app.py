"""
VICC Praxisarbeit - Task-API (Flask + PostgreSQL)

Endpunkte:
  GET    /              Übersicht (HTML, für Browser)
  GET    /health        DB-Konnektivitätscheck (200 / 503)
  GET    /tasks         alle Tasks
  POST   /tasks         Task anlegen      {"title": str, "done": bool?}
  GET    /tasks/<id>    einzelner Task
  PUT    /tasks/<id>    Task aktualisieren {"title": str?, "done": bool?}
  DELETE /tasks/<id>    Task löschen

Konfiguration ausschliesslich über Umgebungsvariablen:
  DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD, DB_SSLMODE
"""

import html
import logging
import os
from contextlib import contextmanager

import psycopg2
import psycopg2.extras
from flask import Flask, jsonify, request

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("vicc-api")

APP_VERSION = os.getenv("APP_VERSION", "2.0.0")

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
    """Legt die Tabelle beim ersten DB-Zugriff an (idempotent)."""
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
    _schema_ready = True
    log.info("Schema bereit")


def row_to_dict(row):
    return {
        "id": row["id"],
        "title": row["title"],
        "done": row["done"],
        "created_at": row["created_at"].isoformat(),
        "updated_at": row["updated_at"].isoformat(),
    }


def fetch_all_tasks():
    ensure_schema()
    with get_conn() as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute("SELECT * FROM tasks ORDER BY id")
        return [row_to_dict(r) for r in cur.fetchall()]


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
    if partial and not values:
        return None, "mindestens 'title' oder 'done' angeben"
    return values, None


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
# Routen
# --------------------------------------------------------------------------- #
@app.get("/")
def index():
    """Einfache HTML-Ansicht für den Browser-Test."""
    try:
        tasks = fetch_all_tasks()
        db_state = "verbunden"
    except psycopg2.Error:
        tasks, db_state = [], "NICHT erreichbar"
    rows = "".join(
        f"<tr><td>{t['id']}</td><td>{html.escape(t['title'])}</td>"
        f"<td>{'✔' if t['done'] else '–'}</td><td>{t['created_at'][:19]}</td></tr>"
        for t in tasks
    ) or '<tr><td colspan="4">Noch keine Tasks – per POST /tasks anlegen.</td></tr>'
    return f"""<!doctype html>
<html lang="de"><head><meta charset="utf-8"><title>VICC Task-API</title>
<style>
 body{{font-family:system-ui,sans-serif;max-width:760px;margin:2rem auto;padding:0 1rem}}
 table{{border-collapse:collapse;width:100%}} td,th{{border:1px solid #ccc;padding:.4rem;text-align:left}}
 code{{background:#f2f2f2;padding:.1rem .3rem}}
</style></head><body>
<h1>VICC Task-API</h1>
<p>Version <code>{APP_VERSION}</code> · Host <code>{html.escape(os.getenv("HOSTNAME", "-"))}</code>
 · Datenbank: <strong>{db_state}</strong></p>
<p>API: <a href="/health">/health</a> · <a href="/tasks">/tasks</a></p>
<table><tr><th>ID</th><th>Titel</th><th>Erledigt</th><th>Erstellt (UTC)</th></tr>{rows}</table>
</body></html>"""


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


@app.get("/tasks")
def list_tasks():
    return jsonify(fetch_all_tasks())


@app.post("/tasks")
def create_task():
    values, err = validate_payload(request.get_json(silent=True), partial=False)
    if err:
        return jsonify(error=err), 400
    ensure_schema()
    with get_conn() as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(
            "INSERT INTO tasks (title, done) VALUES (%s, %s) RETURNING *",
            (values["title"], values.get("done", False)),
        )
        task = row_to_dict(cur.fetchone())
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


@app.put("/tasks/<int:task_id>")
def update_task(task_id):
    values, err = validate_payload(request.get_json(silent=True), partial=True)
    if err:
        return jsonify(error=err), 400
    ensure_schema()
    # Spaltennamen stammen aus validate_payload (Whitelist), Werte als Parameter.
    assignments = ", ".join(f"{col} = %s" for col in values)
    with get_conn() as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(
            f"UPDATE tasks SET {assignments}, updated_at = NOW() WHERE id = %s RETURNING *",
            (*values.values(), task_id),
        )
        row = cur.fetchone()
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


if __name__ == "__main__":
    # Nur für lokale Entwicklung; im Container startet gunicorn.
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "8000")))
