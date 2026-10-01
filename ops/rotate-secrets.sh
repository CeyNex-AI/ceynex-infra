#!/usr/bin/env bash
# Rotate the data-tier credentials and the JWT secret (SAD C4: credentials never
# rotated since they sat in DevOps/ as .env.example values). Run on the VM, in
# a maintenance window, immediately before recreating the containers:
#
#   ops/rotate-secrets.sh            # databases + Redis + JWT
#   ops/rotate-secrets.sh --no-jwt   # keep everyone signed in
#
# then, in order:
#   (cd database && docker compose up -d) && (cd backend && docker compose up -d) \
#     && (cd frontend && docker compose up -d)
#
# Why it must be followed at once: Postgres and Neo4j take the new password the
# moment it is set, and the running API opens new connections with the old one.
# Redis's password is only in its start command, so it changes when Redis is
# recreated. POSTGRES_PASSWORD and NEO4J_AUTH in the compose files only apply
# when a volume is first initialised, which is why the live stores are altered
# here rather than by editing .env alone.
#
# A new JWT secret signs everyone out once. API keys and share links survive:
# neither is a JWT.
#
# Nothing secret is printed. The old .env files are kept, owner-only, in
# ~/backups/env-<stamp>/ for rollback.
set -euo pipefail

INFRA="${CEYNEX_DIR:-$HOME/ceynex}/ceynex-infra"
DB_ENV="$INFRA/database/.env"
API_ENV="$INFRA/backend/.env"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
KEEP="$HOME/backups/env-$STAMP"
ROTATE_JWT=yes
PG_CONTAINER="${PG_CONTAINER:-ceynex-postgres}"
NEO4J_CONTAINER="${NEO4J_CONTAINER:-ceynex-neo4j}"
[ "${1:-}" = "--no-jwt" ] && ROTATE_JWT=no

value() { grep -oP "^$1=\K.*" "$2"; }
set_value() {  # set_value KEY VALUE FILE: replace the line, or append it
  if grep -q "^$1=" "$3"; then
    sed -i "s|^$1=.*|$1=$2|" "$3"
  else
    printf '%s=%s\n' "$1" "$2" >> "$3"
  fi
}
new_secret() { openssl rand -hex 24; }  # hex: nothing to quote in SQL or Cypher

umask 077
mkdir -p "$KEEP"
cp "$DB_ENV" "$KEEP/database.env"
cp "$API_ENV" "$KEEP/backend.env"
echo "old .env files kept in $KEEP"

PGU=$(value POSTGRES_USER "$DB_ENV")
PGD=$(value POSTGRES_DB "$DB_ENV")
OLD_PG=$(value POSTGRES_PASSWORD "$DB_ENV")
OLD_NEO=$(value NEO4J_PASSWORD "$DB_ENV")
NEW_PG=$(new_secret)
NEW_NEO=$(new_secret)
NEW_REDIS=$(new_secret)

# The backend .env repeats the data-tier credentials; a mismatch would only
# show up as authentication errors in the API log, so check before changing.
for key in POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB NEO4J_PASSWORD REDIS_PASSWORD; do
  [ "$(value "$key" "$DB_ENV")" = "$(value "$key" "$API_ENV")" ] \
    || { echo "STOP: $key differs between database/.env and backend/.env"; exit 1; }
done

docker exec -e PGPASSWORD="$OLD_PG" "$PG_CONTAINER" \
  psql -U "$PGU" -d "$PGD" -qc "ALTER ROLE \"$PGU\" PASSWORD '$NEW_PG'" >/dev/null
echo "postgres: password changed"

docker exec "$NEO4J_CONTAINER" cypher-shell -u neo4j -p "$OLD_NEO" -d system \
  "ALTER CURRENT USER SET PASSWORD FROM '$OLD_NEO' TO '$NEW_NEO'" >/dev/null
echo "neo4j: password changed"

for f in "$DB_ENV" "$API_ENV"; do
  set_value POSTGRES_PASSWORD "$NEW_PG" "$f"
  set_value NEO4J_PASSWORD "$NEW_NEO" "$f"
  set_value REDIS_PASSWORD "$NEW_REDIS" "$f"
done
echo "redis: new password written; it applies when ceynex-redis is recreated"

if [ "$ROTATE_JWT" = yes ]; then
  set_value CEYNEX_JWT_SECRET "$(openssl rand -hex 32)" "$API_ENV"
  echo "jwt: new secret written; every session ends when ceynex-api is recreated"
fi

echo "now recreate database, backend and frontend, in that order"
