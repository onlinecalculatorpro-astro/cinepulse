# ---------- base ----------
FROM python:3.11-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app

WORKDIR /app

# add `passwd` so useradd exists
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential ca-certificates passwd \
 && rm -rf /var/lib/apt/lists/*

COPY infra/requirements.txt ./requirements.txt
RUN python -m pip install --upgrade pip setuptools wheel \
 && pip install --no-cache-dir -r requirements.txt

COPY . /app

# Non-root runtime user
RUN useradd -r -u 10001 -g root appuser \
 && chown -R appuser:root /app
USER appuser

# ---------- API ----------
FROM base AS api
EXPOSE 8000
CMD ["uvicorn", "apps.api.app.main:app", "--host", "0.0.0.0", "--port", "8000"]

# ---------- Worker ----------
FROM base AS worker
CMD ["python", "-m", "apps.workers.main"]

# ---------- Scheduler ----------
FROM base AS scheduler
CMD ["python", "-m", "apps.scheduler.main"]

# ---------- Webhooks ----------
FROM base AS webhooks
EXPOSE 8000
CMD ["uvicorn", "apps.webhooks.main:app", "--host", "0.0.0.0", "--port", "8000"]
