# syntax=docker/dockerfile:1
FROM python:3.12-slim

# Sicherheits-/Best-Practice: kein Root-User im Container
RUN useradd --create-home --shell /bin/bash appuser

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

USER appuser

ENV PORT=8000
EXPOSE 8000

# Healthcheck spiegelt den /health-Endpunkt der App
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD python -c "import urllib.request,os,sys; \
    sys.exit(0) if urllib.request.urlopen(f'http://127.0.0.1:{os.environ.get(\"PORT\",8000)}/health').getcode()==200 else sys.exit(1)"

CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "2", "app:app"]
