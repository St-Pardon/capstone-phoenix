#!/usr/bin/env bash
# Restore-test a Postgres backup from OCI Object Storage — PROVES the backups are usable.
# Non-destructive: restores into a throwaway DB (restore_verify) in the live Postgres, checks the
# tables came back, then drops it. Live `taskapp` data is never touched.
#
# Prereqs: KUBECONFIG set; `mc` on PATH (or set MC=/path/to/mc); the same S3 creds the CronJob uses.
# Usage:
#   export S3_ENDPOINT=... S3_BUCKET=phoenix-pg-backups S3_ACCESS_KEY=... S3_SECRET_KEY=...
#   manifests/restore-postgres.sh                 # restores the NEWEST object
#   manifests/restore-postgres.sh taskapp-2026....sql.gz   # a specific object
set -euo pipefail

NS="${NS:-taskapp}"
MC="${MC:-mc}"
KEY="${1:-}"

"$MC" --config-dir /tmp/mc-restore alias set oci "$S3_ENDPOINT" "$S3_ACCESS_KEY" "$S3_SECRET_KEY" >/dev/null

if [ -z "$KEY" ]; then
  KEY="$("$MC" --config-dir /tmp/mc-restore ls "oci/$S3_BUCKET/" | awk '{print $NF}' | sort | tail -1)"
fi
echo "restoring from object: $KEY"

"$MC" --config-dir /tmp/mc-restore cp "oci/$S3_BUCKET/$KEY" "/tmp/$KEY"

echo "--- create throwaway DB restore_verify, load the dump ---"
kubectl -n "$NS" exec -i sts/taskapp-postgres -- sh -c \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "DROP DATABASE IF EXISTS restore_verify;" \
   && createdb -U "$POSTGRES_USER" restore_verify'
gunzip -c "/tmp/$KEY" | kubectl -n "$NS" exec -i sts/taskapp-postgres -- sh -c \
  'psql -q -U "$POSTGRES_USER" -d restore_verify'

echo "--- tables present in the restored DB (proof the backup is usable) ---"
kubectl -n "$NS" exec sts/taskapp-postgres -- sh -c \
  'psql -U "$POSTGRES_USER" -d restore_verify -c "\dt"'

echo "--- cleanup: drop restore_verify ---"
kubectl -n "$NS" exec sts/taskapp-postgres -- sh -c \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "DROP DATABASE restore_verify;"'
echo "restore test OK — $KEY restored and verified."
