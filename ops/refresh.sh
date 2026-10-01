#!/usr/bin/env bash
# Monthly data refresh (SRS v2.0 FR-DAT-03; ceynex-core docs/ARCHITECTURE_DELTA.md
# D19). Cron: 30 4 2 * *, after the 02:00 backup and the 03:30 certificate
# renewal. See ops/crontab.example.
#
# Inside the api container, so it uses the image's code and the deployment's
# credentials exactly as an admin-triggered ingest does:
#   1. fetch_snapshots: a new Pink Sheet workbook, if the World Bank published one
#   2. pipeline: re-ingest every source marked `refresh: true` in config/sources.yaml
#   3. kg.load --flows: rebuild the EXPORTS_TO edges from what fact_trade now holds
#      (never a bare kg.load, which would re-embed the whole policy corpus)
# then logs which sources are still past their cadence, which is also what
# /health's `stale_sources` and its uptime check report.
#
# A failed step does not stop the next: a fetch that fails leaves last month's
# workbook, which still ingests. The exit status is non-zero if any step failed,
# and each failure is also an `ingest_run` row the Admin page shows.
set -uo pipefail

API="${API_CONTAINER:-ceynex-api}"
LOCK="${CEYNEX_OPS_LOCK:-/run/lock/ceynex-ops.lock}"
log() { echo "$(date -u +%FT%TZ) $*"; }

exec 9>"$LOCK"
flock -w 3600 9 || { log "FAIL could not take $LOCK"; exit 1; }

in_api() { docker exec "$API" python -m "$@"; }
status=0

log "refresh: start"
sources=$(docker exec "$API" python -c "
from ceynex import settings
config = settings.load_config('sources')['sources']
print(' '.join(v['connector'] for v in config.values() if v.get('refresh')))
") || { log "FAIL could not read config/sources.yaml in $API"; exit 1; }
log "refresh: sources $sources"

in_api ceynex.data.fetch_snapshots --sources pink_sheet || { status=1; log "WARN snapshot fetch failed"; }
# shellcheck disable=SC2086  # one word per connector, deliberately
in_api ceynex.data.pipeline --sources $sources || { status=1; log "WARN ingest reported a failure"; }
in_api ceynex.kg.load --flows || { status=1; log "WARN graph flows reload failed"; }

docker exec "$API" python -c "
from ceynex.data import freshness
rows = freshness.per_source()
stale = [r.source_id for r in rows if r.stale]
print('refresh: stale after run:', ', '.join(stale) if stale else 'none')
"
log "refresh: done, exit $status"
exit "$status"
