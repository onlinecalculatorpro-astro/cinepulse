# ---------- base ----------
FROM python:3.11-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONPATH=/app

WORKDIR /app

# System deps
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Python deps first (better layer caching)
COPY infra/requirements.txt ./requirements.txt
RUN python -m pip install --upgrade pip setuptools wheel \
 && pip install --no-cache-dir -r requirements.txt

# App code
COPY . /app

# Non-root runtime user
RUN useradd -r -u 10001 -g root appuser \
 && chown -R appuser:root /app
USER appuser

# ---------- API ----------
FROM base AS api
EXPOSE 8000
CMD uvicorn apps.api.app.main:app --host 0.0.0.0 --port 8000

# ---------- Worker ----------
FROM base AS worker
CMD python -m apps.workers.main

# ---------- Scheduler ----------
FROM base AS scheduler
CMD python -m apps.scheduler.main

# ---------- Webhooks ----------
FROM base AS webhooks
EXPOSE 8000
CMD uvicorn apps.webhooks.main:app --host 0.0.0.0 --port 8000

# ---------- Renderer (optional) ----------
FROM base AS renderer
EXPOSE 8000
CMD uvicorn apps.renderer.app.main:app --host 0.0.0.0 --port 8000
