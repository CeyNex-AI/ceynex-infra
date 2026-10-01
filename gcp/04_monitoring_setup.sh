#!/usr/bin/env bash
# Uptime monitoring and alerts (SRS RR-01/RR-04, SAD C11/C15). Run from a
# workstation as a project owner:
#
#   PROJECT=<id> ALERT_EMAIL=<address> bash gcp/04_monitoring_setup.sh
#
# Idempotent. Creates, if missing:
#   - an email notification channel for ALERT_EMAIL;
#   - uptime check "ceynex-health": https://<host>/health every 5 minutes from
#     three regions, passing only on `"status":"ok"` (both databases up). Its
#     pass history is the availability figure RR-01 asks for, and its incidents
#     give RR-04's time between failures;
#   - uptime check "ceynex-stale-sources": the same URL every 15 minutes (the
#     longest period GCP allows), passing only while `stale_sources` is 0;
#   - alert policies: the site down from 2+ regions for 5 minutes; any source
#     stale; the TLS certificate within 14 days of expiry (the renewal cron's
#     safety net).
# No mail server of our own is involved: Cloud Monitoring sends the emails.
set -euo pipefail

PROJECT="${PROJECT:?set PROJECT to the GCP project id}"
ALERT_EMAIL="${ALERT_EMAIL:?set ALERT_EMAIL to the address alerts go to}"
HOST="${HOST:-ceynex.cc}"
REGIONS="${REGIONS:-asia-pacific,europe,usa-oregon}"
g() { gcloud --project "$PROJECT" --quiet "$@"; }
api() {  # api METHOD PATH [JSON]: the Monitoring REST API, for what gcloud GA lacks
  curl -fsS -X "$1" "https://monitoring.googleapis.com/v3/projects/$PROJECT/$2" \
    -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    -H "Content-Type: application/json" ${3:+--data "$3"}
}

g services enable monitoring.googleapis.com

# --- email channel ---------------------------------------------------------------
channel=$(api GET notificationChannels | jq -r --arg e "$ALERT_EMAIL" \
  '.notificationChannels[]? | select(.type=="email" and .labels.email_address==$e) | .name' | head -1)
if [ -z "$channel" ]; then
  channel=$(api POST notificationChannels \
    "$(jq -nc --arg e "$ALERT_EMAIL" '{type:"email",displayName:"CeyNex alerts",labels:{email_address:$e}}')" \
    | jq -r .name)
  echo "channel: created $channel"
else
  echo "channel: $channel exists"
fi

# --- uptime checks -----------------------------------------------------------------
check_id() {
  g monitoring uptime list-configs --filter="displayName=\"$1\"" --format="value(name)" \
    | head -1 | sed 's#.*/##'
}
ensure_check() {  # ensure_check NAME PERIOD MATCHER_TYPE MATCHER_CONTENT
  if [ -z "$(check_id "$1")" ]; then
    g monitoring uptime create "$1" --resource-type=uptime-url \
      --resource-labels="host=$HOST,project_id=$PROJECT" \
      --protocol=https --port=443 --path=/health --validate-ssl=true \
      --period="$2" --timeout=10 --regions="$REGIONS" \
      --matcher-type="$3" --matcher-content="$4" >/dev/null
    echo "uptime: created $1"
  else
    echo "uptime: $1 exists"
  fi
}
ensure_check ceynex-health 5 contains-string '"status":"ok"'
ensure_check ceynex-stale-sources 15 matches-regex '"stale_sources":0[,}]'
HEALTH_ID=$(check_id ceynex-health)
STALE_ID=$(check_id ceynex-stale-sources)

# --- alert policies --------------------------------------------------------------------
existing=$(g monitoring policies list --format="value(displayName)")
ensure_policy() {  # ensure_policy DISPLAY_NAME JSON
  if grep -qxF "$1" <<<"$existing"; then
    echo "policy: $1 exists"
    return
  fi
  local file
  file=$(mktemp --suffix=.json)
  printf '%s' "$2" > "$file"
  g monitoring policies create --policy-from-file="$file" >/dev/null
  rm -f "$file"
  echo "policy: created $1"
}
failing_from() {  # failing_from CHECK_ID ALIGN_SECONDS DURATION_SECONDS REGIONS_OVER
  jq -nc --arg id "$1" --arg align "$2s" --arg dur "$3s" --argjson over "$4" '{
    filter: ("metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" AND metric.label.check_id=\"" + $id + "\" AND resource.type=\"uptime_url\""),
    aggregations: [{alignmentPeriod: $align, perSeriesAligner: "ALIGN_NEXT_OLDER",
                     crossSeriesReducer: "REDUCE_COUNT_FALSE", groupByFields: ["resource.label.*"]}],
    comparison: "COMPARISON_GT", thresholdValue: $over, duration: $dur,
    trigger: {count: 1}}'
}

ensure_policy "CeyNex is down" "$(jq -nc --arg ch "$channel" --argjson cond "$(failing_from "$HEALTH_ID" 300 300 1)" '{
  displayName: "CeyNex is down", combiner: "OR", notificationChannels: [$ch],
  documentation: {mimeType: "text/markdown", content: "https://ceynex.cc/health has failed from 2+ regions for 5 minutes, or both databases are not up. Start with `docker ps` on the VM (ceynex-infra ops/RESTORE.md)."},
  conditions: [{displayName: "health check failing", conditionThreshold: $cond}]}')"

ensure_policy "CeyNex data is stale" "$(jq -nc --arg ch "$channel" --argjson cond "$(failing_from "$STALE_ID" 900 0 1)" '{
  displayName: "CeyNex data is stale", combiner: "OR", notificationChannels: [$ch],
  documentation: {mimeType: "text/markdown", content: "A source is past its refresh cadence (config/sources.yaml). Admin page, Pipeline: Data freshness shows which, and its last error; ~/backups/refresh.log on the VM has the monthly run."},
  conditions: [{displayName: "stale_sources above 0", conditionThreshold: $cond}]}')"

ensure_policy "CeyNex certificate expiring" "$(jq -nc --arg ch "$channel" --arg id "$HEALTH_ID" '{
  displayName: "CeyNex certificate expiring", combiner: "OR", notificationChannels: [$ch],
  documentation: {mimeType: "text/markdown", content: "The TLS certificate for ceynex.cc expires within 14 days, so the 03:30 renewal cron has not been renewing it. See ceynex-infra frontend/README.md, TLS."},
  conditions: [{displayName: "certificate expires within 14 days", conditionThreshold: {
    filter: ("metric.type=\"monitoring.googleapis.com/uptime_check/time_until_ssl_cert_expires\" AND metric.label.check_id=\"" + $id + "\" AND resource.type=\"uptime_url\""),
    aggregations: [{alignmentPeriod: "1200s", perSeriesAligner: "ALIGN_NEXT_OLDER",
                     crossSeriesReducer: "REDUCE_MIN", groupByFields: ["resource.label.host"]}],
    comparison: "COMPARISON_LT", thresholdValue: 14, duration: "600s", trigger: {count: 1}}}]}')"

echo "done: checks $HEALTH_ID, $STALE_ID; alerts to $ALERT_EMAIL"
