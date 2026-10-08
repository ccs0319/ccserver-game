#!/usr/bin/env bash
# Restore the local development databases from a backup directory.
#
#   scripts/restore.sh [timestamp|latest] [-y]
#
# Defaults to the newest backup. Only files present in the backup are restored.
# This OVERWRITES current data. Pass -y (or CCS_RESTORE_YES=1) to skip the prompt.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_ROOT="${CCS_BACKUP_DIR:-$ROOT/backups}"

TARGET="${1:-latest}"
ASSUME_YES="${2:-}"
if [ "$TARGET" = "latest" ]; then
    TARGET="$(ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | sort | tail -1 || true)"
fi
if [ -z "$TARGET" ] || [ ! -d "$TARGET" ]; then
    echo "no backup directory found (looked under $BACKUP_ROOT)" >&2
    exit 1
fi
DEST="$(cd "$TARGET" && pwd)"

MYSQL_C="${CCS_MYSQL_CONTAINER:-ccs-mysql}"
MYSQL_USER="${CCS_MYSQL_USER:-root}"
MYSQL_PASS="${CCS_MYSQL_PASSWORD:-123456}"
PG_C="${CCS_PG_CONTAINER:-ccs-pg}"
PG_USER="${CCS_PG_USER:-ccs}"
PG_DB="${CCS_PG_DB:-game}"
MONGO_C="${CCS_MONGO_CONTAINER:-ccs-mongo}"
REDIS_C="${CCS_REDIS_CONTAINER:-ccs-redis}"

container_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"
}

if [ "$ASSUME_YES" != "-y" ] && [ "${CCS_RESTORE_YES:-}" != "1" ]; then
    echo "About to restore from: $DEST"
    echo "This will OVERWRITE current database data."
    read -r -p "Continue? [y/N] " ans
    case "$ans" in
        [yY]) ;;
        *) echo "aborted"; exit 1 ;;
    esac
fi

restore_mysql() {
    [ -f "$DEST/mysql.sql" ] || return 0
    if container_running "$MYSQL_C"; then
        echo "  [mysql] $MYSQL_C"
        docker exec -i "$MYSQL_C" sh -c "exec mysql -u'$MYSQL_USER' -p'$MYSQL_PASS'" <"$DEST/mysql.sql"
    else
        echo "  [mysql] skipped ($MYSQL_C not running)"
    fi
}

restore_pg() {
    [ -f "$DEST/postgres.sql" ] || return 0
    if container_running "$PG_C"; then
        echo "  [postgres] $PG_C"
        docker exec -i "$PG_C" sh -c "exec psql -v ON_ERROR_STOP=1 -U '$PG_USER' -d '$PG_DB'" <"$DEST/postgres.sql"
    else
        echo "  [postgres] skipped ($PG_C not running)"
    fi
}

restore_mongo() {
    [ -f "$DEST/mongo.archive.gz" ] || return 0
    if container_running "$MONGO_C"; then
        echo "  [mongodb] $MONGO_C"
        docker exec -i "$MONGO_C" sh -c "exec mongorestore --archive --gzip --drop" <"$DEST/mongo.archive.gz"
    else
        echo "  [mongodb] skipped ($MONGO_C not running)"
    fi
}

restore_redis() {
    [ -f "$DEST/redis.rdb" ] || return 0
    if container_running "$REDIS_C"; then
        echo "  [redis] $REDIS_C (copy dump.rdb + restart)"
        docker cp "$DEST/redis.rdb" "$REDIS_C:/data/dump.rdb" >/dev/null
        docker restart "$REDIS_C" >/dev/null
    else
        echo "  [redis] skipped ($REDIS_C not running)"
    fi
}

echo "restoring from $DEST"
restore_mysql
restore_pg
restore_mongo
restore_redis
echo "done."
