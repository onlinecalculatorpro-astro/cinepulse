# ============================================================================
# Base image stage
# This stage bakes in:
#   - Python runtime + deps
#   - All app code (api, workers, scheduler, sanitizer, webhooks, push worker)
#   - infra/source.yml + infra/verticals/*.yml (ingestion config)
#
# All service targets (api / worker / scheduler / webhooks) extend from this.
# ============================================================================

FROM python:3.11-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app

WORKDIR /app

# We install a few system packages:
# - build-essential: lets us build any wheels with C extensions (lxml, Pillow if needed)
# - ca-certificates: TLS/HTTPS validation for httpx, etc.
# - passwd: provides `useradd`, so we can create a non-root runtime user.
#
# NOTE: If later we add heavy image manipulation (renderer service with Pillow),
# you may also want libjpeg, zlib, libpng, etc. Keep slim for now.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        passwd \
 && rm -rf /var/lib/apt/lists/*

# Install Python deps once here so all targets share the same layer.
# infra/requirements.txt should contain ALL runtime deps needed by:
#   - api
#   - workers/sanitizer/push workers
#   - scheduler
#   - webhooks
COPY infra/requirements.txt ./requirements.txt

RUN python -m pip install --upgrade pip setuptools wheel \
 && pip install --no-cache-dir -r requirements.txt

# Now copy the full repo (app code + infra configs).
# This includes:
#   apps/api/...
#   apps/workers/...
#   apps/sanitizer/... (actually lives in apps/sanitizer/)
#   apps/scheduler/... etc.
#   infra/source.yml and infra/verticals/*.yml
COPY . /app

# Create a non-root runtime user for all services.
# UID 10001 is arbitrary but consistent.
RUN useradd -r -u 10001 -g root appuser \
 && chown -R appuser:root /app

USER appuser


# ============================================================================
# API service image
# Runs the FastAPI + uvicorn/gunicorn API:
#   - /v1/feed, /v1/story/{id}, /v1/search
#   - /v1/realtime (SSE+WS)
#   - /v1/img (image proxy)
#
# In docker-compose we actually run gunicorn, but uvicorn here is fine
# as a direct CMD fallback / local debug.
# ============================================================================

FROM base AS api
EXPOSE 8000
CMD ["uvicorn", "apps.api.app.main:app", "--host", "0.0.0.0", "--port", "8000"]


# ============================================================================
# Worker service image
#
# This single stage is reused by:
#   - workers     (RQ queue: "events")
#   - sanitizer   (RQ queue: "sanitize")
#   - push        (RQ queue: "push") [optional]
#
# docker-compose overrides the CMD for each one with:
#   rq worker -u "$REDIS_URL" events        # for workers
#   rq worker -u "$REDIS_URL" sanitize      # for sanitizer
#   rq worker -u "$REDIS_URL" push          # for push
#
# We intentionally DO NOT try to run "python -m apps.workers.main"
# because there is no single main module; RQ is the entrypoint.
#
# So the CMD below is just a harmless default.
# ============================================================================

FROM base AS worker
CMD ["rq", "worker", "-u", "redis://redis:6379/0", "events"]


# ============================================================================
# Scheduler service image
#
# Runs the polling loop:
#   - reads /app/infra/source.yml
#   - merges vertical config files listed under `include_verticals: [...]`
#   - calls youtube_rss_poll() / rss_poll()
#   - enqueues new ingest work into RQ queue "events"
#
# docker-compose uses:
#   command: ["python", "-m", "apps.scheduler.main"]
#
# We leave CMD here too so `docker run` on this target works standalone.
# ============================================================================

FROM base AS scheduler
CMD ["python", "-m", "apps.scheduler.main"]


# ============================================================================
# Webhooks service image
#
# Handles WebSub callbacks (YouTube PubSubHubbub, RSS hubs):
#   - verifies subscriptions
#   - on notify: enqueues a "refresh this channel/feed now" job into "events"
#
# docker-compose runs uvicorn for this.
# ============================================================================

FROM base AS webhooks
EXPOSE 8000
CMD ["uvicorn", "apps.webhooks.main:app", "--host", "0.0.0.0", "--port", "8000"]
