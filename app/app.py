"""
Minimalistische Flask REST-API für die Praxisarbeit VICC.TA1A.PA.

Ressource: /tasks (CRUD)
Persistenz: Azure Database for PostgreSQL (Connection via Umgebungsvariablen)

Hinweis: Diese Applikationslogik (Flask, Python, ggf. eine lokale DB-Bibliothek)
ist gemäss Aufgabenstellung NICHT Teil der VICC-Infrastruktur-Dokumentation.
Sie dient hier lediglich als lauffähige Beispiel-Applikation, um die
bereitgestellte Cloud-Infrastruktur (App Service for Containers +
Azure Database for PostgreSQL) end-to-end zu demonstrieren.
"""

import os
import psycopg2
from psycopg2.extras import RealDictCursor
from flask import Flask, jsonify, request, abort

app = Flask(__name__)

DB_CONFIG = {
    "host": os.environ.get("DB_HOST"),
    "port": os.environ.get("DB_PORT", "5432"),
    "dbname": os.environ.get("DB_NAME"),
    "user": os.environ.get("DB_USER"),
    "password": os.environ.get("DB_PASSWORD"),
    "sslmode": os.environ.get("DB_SSLMODE", "require"),
}


def get_connection():
    return psycopg2.connect(**DB_CONFIG)


def init_db():
    """Legt die Tabelle an, falls sie noch nicht existiert (idempotent)."""
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS tasks (
                    id SERIAL PRIMARY KEY,
                    title VARCHAR(255) NOT NULL,
                    done BOOLEAN NOT NULL DEFAULT FALSE,
                    created_at TIMESTAMP NOT NULL DEFAULT NOW()
                );
                """
            )
        conn.commit()


@app.route("/health", methods=["GET"])
def health():
    """Liveness/Readiness-Endpunkt inkl. DB-Konnektivitätscheck."""
    try:
        with get_connection() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT 1;")
        return jsonify(status="ok", database="reachable"), 200
    except Exception as exc:  # noqa: BLE001
        return jsonify(status="degraded", database="unreachable", error=str(exc)), 503


@app.route("/tasks", methods=["GET"])
def list_tasks():
    with get_connection() as conn:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute("SELECT id, title, done, created_at FROM tasks ORDER BY id;")
            rows = cur.fetchall()
    return jsonify(rows), 200


@app.route("/tasks", methods=["POST"])
def create_task():
    payload = request.get_json(silent=True) or {}
    title = payload.get("title")
    if not title:
        abort(400, description="Feld 'title' ist erforderlich.")
    with get_connection() as conn:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(
                "INSERT INTO tasks (title) VALUES (%s) RETURNING id, title, done, created_at;",
                (title,),
            )
            new_task = cur.fetchone()
        conn.commit()
    return jsonify(new_task), 201


@app.route("/tasks/<int:task_id>", methods=["PUT"])
def update_task(task_id):
    payload = request.get_json(silent=True) or {}
    with get_connection() as conn:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(
                """
                UPDATE tasks
                SET title = COALESCE(%s, title),
                    done  = COALESCE(%s, done)
                WHERE id = %s
                RETURNING id, title, done, created_at;
                """,
                (payload.get("title"), payload.get("done"), task_id),
            )
            updated = cur.fetchone()
        conn.commit()
    if not updated:
        abort(404, description="Task nicht gefunden.")
    return jsonify(updated), 200


@app.route("/tasks/<int:task_id>", methods=["DELETE"])
def delete_task(task_id):
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("DELETE FROM tasks WHERE id = %s;", (task_id,))
            deleted = cur.rowcount
        conn.commit()
    if not deleted:
        abort(404, description="Task nicht gefunden.")
    return "", 204


@app.route("/", methods=["GET"])
def index():
    return jsonify(
        service="vicc-praxisarbeit-api",
        endpoints=["/health", "/tasks (GET, POST)", "/tasks/<id> (PUT, DELETE)"],
    ), 200


# Tabelle beim Container-Start sicherstellen (idempotent, unkritisch bei Kaltstart-Race).
try:
    init_db()
except Exception:  # noqa: BLE001
    # Kann beim allerersten Start auftreten, falls die DB noch nicht bereit ist.
    # Der /health-Endpunkt zeigt den aktuellen Zustand transparent an.
    pass


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8000)))
