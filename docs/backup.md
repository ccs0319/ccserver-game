# Database Backup & Restore

ccserver ships scripts to back up and restore the local development databases
(Redis / MySQL / PostgreSQL / MongoDB). For production, see [Production notes](#production-notes).

## Persistence

`docker-compose.yml` declares **named volumes** so container data survives
`docker compose down` (it is only removed by `docker compose down -v`):

| Service | Volume | Mount |
| --- | --- | --- |
| Redis | `redis-data` | `/data` |
| MySQL | `mysql-data` | `/var/lib/mysql` |
| PostgreSQL | `pg-data` | `/var/lib/postgresql/data` |
| MongoDB | `mongo-data` | `/data/db` |

> Volumes are scoped to the compose project name. If you previously ran the
> databases without volumes, recreate them once: `make db-reset` (destructive).

## Manual backup

```bash
scripts/backup.sh          # or: make backup
```

Writes to `backups/<YYYYmmdd_HHMMSS>/`:

| File | Source command |
| --- | --- |
| `mysql.sql` | `mysqldump --all-databases --single-transaction --routines --events` |
| `postgres.sql` | `pg_dump --clean --if-exists` |
| `mongo.archive.gz` | `mongodump --archive --gzip` |
| `redis.rdb` | `redis-cli SAVE` + copy `dump.rdb` (container) or `redis-cli --rdb` (host) |
| `MANIFEST` | timestamp + file sizes |

Only services whose container is running are backed up. The newest
`CCS_BACKUP_KEEP` (default **7**) directories are kept; older ones are pruned.

Environment overrides: `CCS_BACKUP_DIR`, `CCS_BACKUP_KEEP`,
`CCS_{MYSQL,PG,MONGO,REDIS}_CONTAINER`, `CCS_MYSQL_USER/PASSWORD`,
`CCS_PG_USER/DB`, `CCS_REDIS_HOST/PORT`.

## Restore

```bash
scripts/restore.sh                # newest backup, prompts for confirmation
scripts/restore.sh 20260101_030000
scripts/restore.sh latest -y      # skip the prompt
# or: make restore RESTORE=latest
```

Restores only the files present in the chosen backup. This **overwrites** current
data. Redis restore copies `dump.rdb` back and restarts the container.

## Scheduling (periodic backups)

Use cron on the host (recommended for dev/small deployments). Example crontab
(hourly, keep 7 days already handled by the script; log output):

```cron
# m h dom mon dow command
0 * * * * cd /path/to/ccserver && scripts/backup.sh >> logs/backup.log 2>&1
```

A more granular scheme:

```cron
0 3 * * *   cd /path/to/ccserver && scripts/backup.sh >> logs/backup.log 2>&1   # daily 03:00
```

For container-native scheduling, add a sidecar/`ofelia` job that runs
`scripts/backup.sh` inside a container with the Docker socket mounted. Off-site
copies (S3/rsync) should be layered on top of the local backup directory.

## Production notes

The scripts here target **local development**. For production:

- **MySQL**: enable binlog + periodic `xtrabackup`/`mysqldump`; or use managed
  automated backups. Point-in-time recovery needs binlog archiving.
- **PostgreSQL**: enable WAL archiving (`archive_mode=on`, `archive_command`) for
  PITR, and/or streaming replication; take `pg_basebackup` for base backups.
- **Redis**: enable AOF (`appendonly yes`) and/or replicas; snapshot (`BGSAVE`)
  is already available, but RDB alone can lose recent writes.
- **MongoDB**: use replica sets (oplog) + `mongodump`/filesystem snapshots.
- Always store backups **off the database host**, verify restores regularly, and
  encrypt backups at rest.

## Files

| Path | Role |
| --- | --- |
| `scripts/backup.sh` | create a timestamped backup |
| `scripts/restore.sh` | restore from a backup |
| `docker-compose.yml` | named volumes for persistence |
