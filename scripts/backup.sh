#!/usr/bin/env bash
# Back up the local development databases into a timestamped directory.
#
#   scripts/backup.sh
#
# Writes to $CCS_BACKUP_DIR (default: <repo>/backups/<YYYYmmdd_HHMMSS>/):
#   mysql.sql          mysqldump --all-databases --single-transaction
#   postgres.sql       pg_dump --clean --if-exists
#   mongo.archive.gz   mongodump --archive --gzip
#   redis.rdb          redis-cli SAVE (container) or --rdb (host)
#
# Only services whose container is running are backed up (others are skipped).
# Keeps the newest $CCS_BACKUP_KEEP directories (default 7).
#
# Env overrides:
#   CCS_BACKUP_DIR, CCS_BACKUP_KEEP
#   CCS_MYSQL_CONTAINER (ccs-mysql), CCS_MYSQL_USER (root), CCS_MYSQL_PASSWORD (123456)
#   CCS_PG_CONTAINER (ccs-pg), CCS_PG_USER (ccs), CCS_PG_DB (game)
#   CCS_MONGO_CONTAINER (ccs-mongo)
#   CCS_REDIS_CONTAINER (ccs-redis), CCS_REDIS_HOST (127.0.0.1), CCS_REDIS_PORT (6379)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_ROOT="${CCS_BACKUP_DIR:-$ROOT/backups}"
KEEP="${CCS_BACKUP_KEEP:-7}"
TS="$(date +%Y%m%d_%H%M%S)"
DEST="$BACKUP_ROOT/$TS"

MYSQL_C="${CCS_MYSQL_CONTAINER:-ccs-mysql}"
MYSQL_USER="${CCS_MYSQL_USER:-root}"
MYSQL_PASS="${CCS_MYSQL_PASSWORD:-123456}"
PG_C="${CCS_PG_CONTAINER:-ccs-pg}"
PG_USER="${CCS_PG_USER:-ccs}"
PG_DB="${CCS_PG_DB:-game}"
MONGO_C="${CCS_MONGO_CONTAINER:-ccs-mongo}"
REDIS_C="${CCS_REDIS_CONTAINER:-ccs-redis}"
REDIS_HOST="${CCS_REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${CCS_REDIS_PORT:-6379}"

container_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"
}

sha256() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        echo "-"
    fi
}

mkdir -p "$DEST"
echo "backup -> $DEST"

backup_mysql() {
    if container_running "$MYSQL_C"; then
        echo "  [mysql] $MYSQL_C"
        docker exec "$MYSQL_C" sh -c \
            "exec mysqldump -u'$MYSQL_USER' -p'$MYSQL_PASS' --single-transaction --routines --events --all-databases" \
            >"$DEST/mysql.sql"
    else
        echo "  [mysql] skipped ($MYSQL_C not running)"
    fi
}

backup_pg() {
    if container_running "$PG_C"; then
        echo "  [postgres] $PG_C"
        docker exec "$PG_C" sh -c \
            "exec pg_dump -U '$PG_USER' -d '$PG_DB' --clean --if-exists" \
            >"$DEST/postgres.sql"
    else
        echo "  [postgres] skipped ($PG_C not running)"
    fi
}

backup_mongo() {
    if container_running "$MONGO_C"; then
        echo "  [mongodb] $MONGO_C"
        docker exec "$MONGO_C" sh -c "exec mongodump --archive --gzip" \
            >"$DEST/mongo.archive.gz"
    else
        echo "  [mongodb] skipped ($MONGO_C not running)"
    fi
}

backup_redis() {
    if container_running "$REDIS_C"; then
        echo "  [redis] $REDIS_C (SAVE + copy dump.rdb)"
        docker exec "$REDIS_C" redis-cli SAVE >/dev/null
        docker cp "$REDIS_C:/data/dump.rdb" "$DEST/redis.rdb" >/dev/null
    elif command -v redis-cli >/dev/null 2>&1; then
        echo "  [redis] host $REDIS_HOST:$REDIS_PORT (--rdb)"
        if ! redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" --rdb "$DEST/redis.rdb" >/dev/null 2>&1; then
            echo "  [redis] host backup failed (is a server reachable?)"
            rm -f "$DEST/redis.rdb"
        fi
    else
        echo "  [redis] skipped (no container, no redis-cli)"
    fi
}

backup_mysql
backup_pg
backup_mongo
backup_redis

# Manifest for restore / integrity verification (name size sha256).
{
    echo "created_at=$TS"
    echo "host=$(hostname)"
    for f in "$DEST"/*; do
        [ -e "$f" ] || continue
        base="$(basename "$f")"
        [ "$base" = "MANIFEST" ] && continue
        echo "$base $(wc -c <"$f" | tr -d ' ') $(sha256 "$f")"
    done
} >"$DEST/MANIFEST"

if [ -z "$(ls -A "$DEST" | grep -v MANIFEST || true)" ]; then
    echo "no data backed up (no service reachable); removing empty dir"
    rm -rf "$DEST"
    exit 0
fi

# Retention: keep the newest $KEEP timestamp directories.
dirs=($(ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | sort))
count=${#dirs[@]}
if [ "$count" -gt "$KEEP" ]; then
    remove=$((count - KEEP))
    for ((i = 0; i < remove; i++)); do
        echo "  [retention] removing ${dirs[$i]}"
        rm -rf "${dirs[$i]}"
    done
fi

echo "done."
