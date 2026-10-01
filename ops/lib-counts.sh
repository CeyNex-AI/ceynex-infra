# shellcheck shell=bash
# The counts a backup records and a restore must reproduce. Sourced by
# ops/backup.sh (against the live stores) and ops/restore-drill.sh (against a
# restored copy), so both sides run the very same queries.
#
# The caller defines:
#   psql_in SQL       run SQL in the Postgres being counted (-At -F, output)
#   cypher_in CYPHER  run Cypher in the Neo4j being counted (--format plain)
#   QDRANT            base URL of the Qdrant being counted

collect_counts() {
  local dir="$1"
  psql_in "SELECT table_name,
             (xpath('/row/c/text()',
               query_to_xml(format('SELECT count(*) AS c FROM %I.%I', table_schema, table_name),
                            false, true, '')))[1]::text
           FROM information_schema.tables
           WHERE table_schema = 'public' AND table_type = 'BASE TABLE' ORDER BY 1" \
    > "$dir/.pg_rows"
  # The upsert key bootstrap.py creates. A restore that loses it still serves
  # answers, then duplicates every row on the next ingest instead of updating it.
  psql_in "SELECT count(*) FROM pg_constraint WHERE conname = 'fact_trade_upsert_key'" \
    > "$dir/.pg_upsert"
  cypher_in "MATCH (n) UNWIND labels(n) AS l RETURN l, count(*) ORDER BY l" > "$dir/.neo4j_labels"
  cypher_in "MATCH ()-[r]->() RETURN type(r), count(*) ORDER BY type(r)" > "$dir/.neo4j_rels"
  cypher_in "SHOW CONSTRAINTS YIELD name RETURN count(name)" > "$dir/.neo4j_constraints"
  local c
  for c in ceynex_policy ceynex_news; do
    curl -fsS "$QDRANT/collections/$c" | jq -r '.result.points_count' > "$dir/.qdrant_$c"
  done
}

clear_counts() {
  rm -f "$1"/.pg_* "$1"/.neo4j_* "$1"/.qdrant_*
}
