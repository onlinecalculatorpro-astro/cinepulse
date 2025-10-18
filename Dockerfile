FROM python:3.11-slim
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
RUN apt-get update && apt-get install -y --no-install-recommends build-essential curl && rm -rf /var/lib/apt/lists/*

# Install API requirements if present
COPY apps/api/requirements.txt /app/apps/api/requirements.txt
RUN [ -f /app/apps/api/requirements.txt ] && pip install -r /app/apps/api/requirements.txt || true

# (optional) root requirements
COPY requirements.txt /app/requirements.txt
RUN [ -f /app/requirements.txt ] && pip install -r /app/requirements.txt || true

# Copy source
COPY . .

# Start FastAPI (module is apps.api.app.main:app)
CMD ["gunicorn","apps.api.app.main:app","-k","uvicorn.workers.UvicornWorker","--bind","0.0.0.0:8000","--workers","2"]
