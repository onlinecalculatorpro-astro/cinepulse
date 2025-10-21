# ---------- base ----------
FROM python:3.11-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app

# system deps kept minimal; add build tools only if wheels are unavailable
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Python deps first for better caching
COPY infra/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir --upgrade pip \
 && pip install --no-cache-dir -r requirements.txt

# App source
COPY . /app

# Create non-root user (works with read_only + tmpfs:/tmp in compose)
RUN useradd -r -u 10001 -g root appuser \
 && chown -R appuser:root /app
USER appuser

# ---------- API ----------
FROM base AS api
EXPOSE 8000
# Compose uses gunicorn, but keep a sensible default for local runs:
CMD ["uvicorn", "apps.api.app.main:app", "--host", "0.0.0.0", "--port", "8000"]

# ---------- Worker ----------
FROM base AS worker
# Compose runs: rq worker ...  (this CMD is a harmless default for local runs)
CMD ["python", "-m", "apps.workers.main"]

# ---------- Scheduler ----------
FROM base AS scheduler
CMD ["python", "-m", "apps.scheduler.main"]

# ---------- Webhooks (push ingestion) ----------
FROM base AS webhooks
EXPOSE 8000
# Matches apps/webhooks/main.py -> module path apps.webhooks.main:app
CMD ["uvicorn", "apps.webhooks.main:app", "--host", "0.0.0.0", "--port", "8000"]

# ---------- Renderer (optional) ----------
FROM base AS renderer
EXPOSE 8000
# Your file is apps/renderer/app/main.py -> apps.renderer.app.main:app
CMD ["uvicorn", "apps.renderer.app.main:app", "--host", "0.0.0.0", "--port", "8000"]
