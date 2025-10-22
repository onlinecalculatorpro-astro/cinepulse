
# ---------- base ----------
FROM python:3.11-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY infra/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir --upgrade pip \
 && pip install --no-cache-dir -r requirements.txt

COPY . /app

RUN useradd -r -u 10001 -g root appuser \
 && chown -R appuser:root /app
USER appuser

# ---------- API ----------
FROM base AS api
EXPOSE 8000
CMD uvicorn apps.api.app.main:app --host 0.0.0.0 --port 8000

# ---------- Worker ----------
FROM base AS worker
CMD python -m apps.workers.cli

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
