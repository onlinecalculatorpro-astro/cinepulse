#!/usr/bin/env bash
set -euo pipefail
C="docker compose -f infra/compose.yml"

echo "== API /health =="
curl -fsS http://127.0.0.1:18000/health | jq .

echo "== Feed sample =="
curl -fsS 'http://127.0.0.1:18000/v1/feed?tab=all&limit=10' | jq '{count:(.items|length), sources:(.items[].source)//empty}' 2>/dev/null || true

echo "== Worker ps =="
$C ps | awk '/worker/{print}'

echo "== Redis PING =="
$C exec redis redis-cli ping

echo "== Postgres SELECT 1 =="
$C exec db bash -lc 'psql -U postgres -d cinepulse -tAc "SELECT 1"'

echo "== Scheduler tail =="
$C logs --tail=30 scheduler || true

echo "OK"
