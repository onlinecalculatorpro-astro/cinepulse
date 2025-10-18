#!/usr/bin/env bash
set -euo pipefail
stamp=$(date +%F_%H%M)
docker exec -i cinepulse-db-1 pg_dump -U postgres -d cinepulse > /root/db_backups/cinepulse_${stamp}.sql
find /root/db_backups -type f -name 'cinepulse_*.sql' -mtime +14 -delete
