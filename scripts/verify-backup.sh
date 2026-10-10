#!/usr/bin/env bash
# Verify a backup directory's integrity against its MANIFEST (size + sha256).
#
#   scripts/verify-backup.sh [timestamp|latest]
#
# Exits non-zero if any file is missing or mismatched. Use it from cron after a
# backup to detect silent corruption, and periodically to validate old backups.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_ROOT="${CCS_BACKUP_DIR:-$ROOT/backups}"

TARGET="${1:-latest}"
if [ "$TARGET" = "latest" ]; then
    TARGET="$(ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | sort | tail -1 || true)"
fi
if [ -z "$TARGET" ] || [ ! -d "$TARGET" ]; then
    echo "no backup directory found (looked under $BACKUP_ROOT)" >&2
    exit 1
fi
DEST="$(cd "$TARGET" && pwd)"

sha256() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        echo "-"
    fi
}

if [ ! -f "$DEST/MANIFEST" ]; then
    echo "no MANIFEST in $DEST" >&2
    exit 1
fi

fail=0
while read -r name size hash; do
    case "$name" in
        created_at=* | host=* | "") continue ;;
    esac
    file="$DEST/$name"
    if [ ! -f "$file" ]; then
        echo "  MISSING  $name"
        fail=1
        continue
    fi
    actual_size="$(wc -c <"$file" | tr -d ' ')"
    if [ "$actual_size" != "$size" ]; then
        echo "  SIZE     $name ($actual_size != $size)"
        fail=1
    fi
    if [ "$hash" != "-" ]; then
        actual_hash="$(sha256 "$file")"
        if [ "$actual_hash" != "$hash" ]; then
            echo "  SHA256   $name mismatch"
            fail=1
        fi
    fi
done <"$DEST/MANIFEST"

if [ "$fail" = 0 ]; then
    echo "verify OK: $DEST"
else
    echo "verify FAILED: $DEST" >&2
    exit 1
fi
