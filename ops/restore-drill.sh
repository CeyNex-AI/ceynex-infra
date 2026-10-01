#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Restore the newest off-VM backup into a throwaway stack and prove it is
# whole (SRS DB-13: a backup is only a backup once a restore has worked).
# Run on a disposable VM, never on production; ops/RESTORE.md has the commands
# that create and delete one.
#
#   BACKUP_BUCKET=<bucket> ops/restore-drill.sh [STAMP]
#   DRILL_FROM=<backup run directory> ops/restore-drill.sh     (no GCS: a local copy)
#
# Exit 0 only when every count in the backup's manifest.json is reproduced by
# the restored copy, the volume archives are intact, and (with
# BACKUP_PASSPHRASE_FILE) the configuration archive decrypts.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DRILL_FROM="${DRILL_FROM:-}"
[ -n "$DRILL_FROM" ] || : "${BACKUP_BUCKET:?set BACKUP_BUCKET, or DRILL_FROM for a local copy}"
WORK="${DRILL_DIR:-$HOME/restore-drill}"
COMPOSE=(docker compose -p restoredrill -f "$HERE/restore-drill.compose.yml")
export DRILL_PASSWORD
DRILL_PASSWORD="$(openssl rand -hex 16)"

stamp="${1:-}"
if [ -n "$DRILL_FROM" ]; then
  stamp=$(basename "$DRILL_FROM")
elif [ -z "$stamp" ]; then
  stamp=$(gcloud storage ls "gs://$BACKUP_BUCKET/daily/" | sed -E 's#.*/daily/([^/]+)/$#\1#' | sort | tail -1)
fi
echo "drill: restoring backup $stamp"
dir="$WORK/$stamp"
mkdir -p "$dir"
if [ -n "$DRILL_FROM" ]; then
  cp -a "$DRILL_FROM"/. "$dir/"
else
  gcloud storage cp --quiet --recursive "gs://$BACKUP_BUCKET/daily/$stamp/*" "$dir/"
fi
(cd "$dir" && sha256sum --quiet -c SHA256SUMS)
echo "drill: checksums match"

cleanup() { [ "${KEEP:-0}" = 1 ] || "${COMPOSE[@]}" down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT
"${COMPOSE[@]}" up -d --wait

psql_in() {
  "${COMPOSE[@]}" exec -T -e PGPASSWORD="$DRILL_PASSWORD" postgres \
    psql -U drill -d ceynex -At -F, -c "$1"
}
cypher_in() {
  "${COMPOSE[@]}" exec -T neo4j cypher-shell -u neo4j -p "$DRILL_PASSWORD" --format plain "$1"
}
QDRANT="http://127.0.0.1:16333"

# --- Postgres: the dump's owner is production's role, so restore without owners.
"${COMPOSE[@]}" exec -T -e PGPASSWORD="$DRILL_PASSWORD" postgres \
  pg_restore -U drill -d ceynex --no-owner --no-privileges --exit-on-error \
  < "$dir/ceynex-postgres.dump"
echo "drill: postgres restored"

# --- Neo4j: the export is plain cypher-shell input, unwrapped at backup time.
"${COMPOSE[@]}" exec -T neo4j cypher-shell -u neo4j -p "$DRILL_PASSWORD" \
  < "$dir/ceynex-neo4j.cypher" >/dev/null
echo "drill: neo4j restored"

# --- Qdrant: upload each snapshot, which recreates the collection from it.
for c in ceynex_policy ceynex_news; do
  curl -fsS -X POST "$QDRANT/collections/$c/snapshots/upload?priority=snapshot" \
    -F "snapshot=@$dir/$c.snapshot" >/dev/null
done
echo "drill: qdrant restored"

# --- Volumes: the archives must list and decompress end to end.
for v in models_data dataset_data; do
  listing=$(tar tzf "$dir/$v.tgz")   # fails the drill if the archive is corrupt
  files=$(grep -vc '/$' <<<"$listing" || true)
  echo "drill: $v.tgz intact, $files files"
done
# An empty model registry looks exactly like a working one: every forecast just
# falls back to the drift baseline. Count the versions, and those whose
# metadata.json records backtest metrics (what `registry.load_best` ranks on).
registry=$(mktemp -d)
tar xzf "$dir/models_data.tgz" -C "$registry"
python3 - "$registry" <<'PY'
import json, pathlib, sys
versions = list(pathlib.Path(sys.argv[1]).rglob("metadata.json"))
scored = sum(1 for p in versions if json.loads(p.read_text()).get("metrics"))
print(f"drill: model registry holds {len(versions)} versions, {scored} with metrics")
PY
rm -rf "$registry"

# --- Configuration: decrypts, when the drill is given the passphrase.
if [ -n "${BACKUP_PASSPHRASE_FILE:-}" ] && [ -f "$dir/config.tar.gz.gpg" ]; then
  gpg --batch --quiet --passphrase-file "$BACKUP_PASSPHRASE_FILE" -d "$dir/config.tar.gz.gpg" \
    | tar tzf - | sed 's/^/drill: config holds /'
fi

# --- The counts.
# shellcheck source=lib-counts.sh
. "$HERE/lib-counts.sh"
collect_counts "$dir"
python3 "$HERE/manifest.py" build "$dir" "restored-$stamp" > "$dir/restored.json"
clear_counts "$dir"
python3 "$HERE/manifest.py" compare "$dir/manifest.json" "$dir/restored.json"
