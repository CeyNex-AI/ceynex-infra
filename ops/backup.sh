#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Nightly application-consistent backup of every CeyNex datastore, copied off
# the VM (SRS DB-11..DB-13, SAD C2). Runs from cron at 02:00 UTC; see
# ops/crontab.example and ops/RESTORE.md.
#
# One directory per run, $BACKUP_DIR/<UTC stamp>/, holding:
#   ceynex-postgres.dump      pg_dump -Fc of the whole database
#   ceynex-neo4j.cypher       APOC cypher-shell export, unwrapped (see below)
#   ceynex_policy.snapshot    Qdrant snapshot of the policy corpus index
#   ceynex_news.snapshot      Qdrant snapshot of the news index
#   models_data.tgz           the trained model registry (exists nowhere else)
#   dataset_data.tgz          raw extracts and the Parquet mirror
#   config.tar.gz.gpg         .env files, TLS state, crontabs: encrypted, because
#                             they hold every credential in the deployment
#   manifest.json             the counts a restore must reproduce
#
# Then, when BACKUP_BUCKET is set, the directory goes to
#   gs://$BACKUP_BUCKET/daily/<stamp>/     (deleted by lifecycle after 90 days)
#   gs://$BACKUP_BUCKET/weekly/<stamp>/    (Sundays; deleted after 365 days)
# and local copies older than KEEP_LOCAL_DAYS are removed, but only once the
# upload of the newest run has been confirmed.
#
# Pre-2026-10 history: this began as ~/ceynex-backup.sh on the VM, which already
# covered Qdrant and the backend volumes (the gaps the 2026-09-07 rescue found)
# but kept everything on the VM's own disk for 7 days.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
[ -f "$HERE/backup.env" ] && . "$HERE/backup.env"

CEYNEX_DIR="${CEYNEX_DIR:-$HOME/ceynex}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/backups}"
BACKUP_BUCKET="${BACKUP_BUCKET:-}"
BACKUP_PASSPHRASE_FILE="${BACKUP_PASSPHRASE_FILE:-$HOME/.ceynex-backup-passphrase}"
KEEP_LOCAL_DAYS="${KEEP_LOCAL_DAYS:-7}"
WEEKLY_DAY="${WEEKLY_DAY:-7}"            # `date +%u`: 7 is Sunday
LOCK="${CEYNEX_OPS_LOCK:-/run/lock/ceynex-ops.lock}"
QDRANT="${QDRANT_LOCAL_URL:-http://127.0.0.1:6333}"

# One ops job at a time: a refresh (ops/refresh.sh) writing fact_trade while
# pg_dump reads it would still be consistent, but two jobs fighting for the
# same 4 vCPUs at night helps neither.
exec 9>"$LOCK"
flock -w 3600 9 || { echo "$(date -u +%FT%TZ) FAIL could not take $LOCK"; exit 1; }

DB_ENV="$CEYNEX_DIR/ceynex-infra/database/.env"
env_value() { grep -oP "^$1=\K.*" "$DB_ENV"; }
PGU=$(env_value POSTGRES_USER)
PGD=$(env_value POSTGRES_DB)
PGPW=$(env_value POSTGRES_PASSWORD)
NPW=$(env_value NEO4J_PASSWORD)

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT="$BACKUP_DIR/$STAMP"
mkdir -p "$OUT"
chmod 700 "$OUT"

psql_in() {
  docker exec -e PGPASSWORD="$PGPW" ceynex-postgres psql -U "$PGU" -d "$PGD" -At -F, -c "$1"
}
cypher_in() {
  docker exec ceynex-neo4j cypher-shell -u neo4j -p "$NPW" --format plain "$1"
}

# --- Postgres ---------------------------------------------------------------
docker exec -e PGPASSWORD="$PGPW" ceynex-postgres pg_dump -U "$PGU" -d "$PGD" -Fc \
  > "$OUT/ceynex-postgres.dump"

# --- Neo4j ------------------------------------------------------------------
# cypher-shell --format plain wraps its single string result in one quoted
# field: a "cypherStatements" header line, a leading quote, a trailing quote,
# and every internal " escaped as \". Piping that straight back into
# cypher-shell fails on line 1, which is exactly what the 2026-09-07 restore
# hit. Unwrapped here, so the stored file is directly restorable with
#   docker exec -i ceynex-neo4j cypher-shell -u neo4j -p PW < ceynex-neo4j.cypher
cypher_in "CALL apoc.export.cypher.all(null,{stream:true,format:'cypher-shell'}) YIELD cypherStatements RETURN cypherStatements;" \
  | sed "1d; 2s/^\"//; \$d; s/\\\\\"/\"/g" \
  > "$OUT/ceynex-neo4j.cypher"

# --- Qdrant -----------------------------------------------------------------
# Snapshot, download, then delete the server-side copy: snapshots land in
# /qdrant/snapshots inside the container, not on the backed-up volume, and
# would otherwise grow by ~30 MB a night.
for c in ceynex_policy ceynex_news; do
  name=$(curl -fsS -X POST "$QDRANT/collections/$c/snapshots" | jq -r '.result.name')
  curl -fsS "$QDRANT/collections/$c/snapshots/$name" -o "$OUT/$c.snapshot"
  curl -fsS -X DELETE "$QDRANT/collections/$c/snapshots/$name" >/dev/null
done

# --- Backend volumes --------------------------------------------------------
for v in models_data dataset_data; do
  docker run --rm --user "$(id -u):$(id -g)" -v "backend_$v:/v:ro" -v "$OUT:/out" alpine \
    tar czf "/out/$v.tgz" -C /v .
done

# --- Configuration, encrypted -----------------------------------------------
# Everything a rebuilt VM needs that is not data: the three .env files, the
# Let's Encrypt state and Cloudflare token, the cert renewal script and both
# crontabs. Symmetric GPG, with a passphrase kept in a file on the VM *and* in
# the team's password manager: on the VM alone it would be lost with the disk
# this exists to survive. No passphrase file, no config copy, said loudly.
if [ -s "$BACKUP_PASSPHRASE_FILE" ]; then
  stage=$(mktemp -d)
  trap 'rm -rf "$stage"' EXIT
  for d in database backend frontend; do
    cp "$CEYNEX_DIR/ceynex-infra/$d/.env" "$stage/$d.env"
  done
  crontab -l > "$stage/crontab.user" 2>/dev/null || true
  # Root's crontab read with sudo, written as this user into the stage: intended.
  # shellcheck disable=SC2024
  sudo -n crontab -l > "$stage/crontab.root" 2>/dev/null || true
  [ -f "$HOME/renew-cert.sh" ] && cp "$HOME/renew-cert.sh" "$stage/"
  sudo -n tar czf "$stage/letsencrypt.tgz" -C "$HOME" letsencrypt 2>/dev/null || true
  tar czf - -C "$stage" . \
    | gpg --batch --yes --symmetric --cipher-algo AES256 \
          --passphrase-file "$BACKUP_PASSPHRASE_FILE" -o "$OUT/config.tar.gz.gpg"
else
  echo "$(date -u +%FT%TZ) WARN no passphrase at $BACKUP_PASSPHRASE_FILE: configuration not backed up"
fi

# --- Manifest: what a restore must reproduce ---------------------------------
# ops/restore-drill.sh recomputes the same counts from a restored copy, through
# the same queries (ops/lib-counts.sh), and compares.
. "$HERE/lib-counts.sh"
collect_counts "$OUT"
python3 "$HERE/manifest.py" build "$OUT" "$STAMP" > "$OUT/manifest.json"
clear_counts "$OUT"

# --- Refuse to keep anything obviously truncated ------------------------------
for f in ceynex-postgres.dump ceynex-neo4j.cypher ceynex_policy.snapshot ceynex_news.snapshot \
         models_data.tgz dataset_data.tgz manifest.json; do
  [ -s "$OUT/$f" ] || { echo "$(date -u +%FT%TZ) FAIL empty: $OUT/$f"; exit 1; }
done
(cd "$OUT" && sha256sum -- * > SHA256SUMS)

# --- Off the VM -----------------------------------------------------------------
uploaded=no
if [ -n "$BACKUP_BUCKET" ]; then
  gcloud storage cp --quiet --no-user-output-enabled --recursive "$OUT" "gs://$BACKUP_BUCKET/daily/"
  if [ "$(date -u +%u)" = "$WEEKLY_DAY" ]; then
    gcloud storage cp --quiet --no-user-output-enabled --recursive "$OUT" "gs://$BACKUP_BUCKET/weekly/"
  fi
  # Confirmed by reading back what landed, not by trusting the exit status alone.
  expected=$(find "$OUT" -maxdepth 1 -type f | wc -l)
  landed=$(gcloud storage ls "gs://$BACKUP_BUCKET/daily/$STAMP/" | wc -l)
  [ "$landed" -eq "$expected" ] && uploaded=yes
  [ "$uploaded" = yes ] || { echo "$(date -u +%FT%TZ) FAIL upload: $landed of $expected objects"; exit 1; }
else
  echo "$(date -u +%FT%TZ) WARN BACKUP_BUCKET unset: this run exists only on this VM"
fi

# --- Local retention --------------------------------------------------------------
# Only after a confirmed upload, so a broken bucket never also eats the local
# copies. Also clears the flat-layout files the pre-2026-10 script left behind.
if [ "$uploaded" = yes ]; then
  find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '20*Z' -mtime +"$KEEP_LOCAL_DAYS" \
    -exec rm -rf {} +
  find "$BACKUP_DIR" -maxdepth 1 -type f \
    \( -name 'ceynex-*' -o -name '*_data-*' -o -name '*.snapshot' \) -mtime +"$KEEP_LOCAL_DAYS" -delete
fi

echo "$(date -u +%FT%TZ) ok  $STAMP uploaded=$uploaded" \
     "pg=$(stat -c%s "$OUT/ceynex-postgres.dump")" \
     "neo4j=$(stat -c%s "$OUT/ceynex-neo4j.cypher")" \
     "qdrant=$(stat -c%s "$OUT/ceynex_policy.snapshot")+$(stat -c%s "$OUT/ceynex_news.snapshot")" \
     "models=$(stat -c%s "$OUT/models_data.tgz")" \
     "dataset=$(stat -c%s "$OUT/dataset_data.tgz")"
