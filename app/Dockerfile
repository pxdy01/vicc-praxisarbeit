# VICC Task-API – Produktionsimage
FROM python:3.12-slim

ARG APP_VERSION=2.0.0

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PORT=8000 \
    GUNICORN_WORKERS=2 \
    APP_VERSION=${APP_VERSION}

WORKDIR /app

# Abhängigkeiten separat kopieren -> Layer-Cache bei Code-Änderungen
COPY requirements.txt .
RUN pip install -r requirements.txt

COPY app.py .

# Dedizierter Nicht-root-User
RUN groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app \
 && chown -R app:app /app
USER app

EXPOSE 8000

# /health prüft die DB-Verbindung; slim-Image hat kein curl -> Python-urllib
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD python -c "import os,urllib.request,sys; sys.exit(0 if urllib.request.urlopen(f'http://127.0.0.1:{os.environ.get(\"PORT\",\"8000\")}/health', timeout=4).status == 200 else 1)"

# Shell-Form nötig, damit ${PORT} zur Laufzeit aufgelöst wird; exec -> gunicorn ist PID 1
CMD ["sh", "-c", "exec gunicorn --bind 0.0.0.0:${PORT} --workers ${GUNICORN_WORKERS} --timeout 60 --access-logfile - --error-logfile - app:app"]
