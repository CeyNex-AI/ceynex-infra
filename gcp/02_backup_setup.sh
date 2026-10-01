#!/usr/bin/env bash
# Off-VM backups for the single-VM deployment (SRS DB-11..DB-13, SAD C1/C2).
# Run from a workstation with gcloud signed in as a project owner, from the
# repo root:
#
#   PROJECT=<project-id> bash gcp/02_backup_setup.sh
#   PROJECT=<project-id> bash gcp/02_backup_setup.sh --switch-service-account
#
# Idempotent: every step checks before it changes anything. Without the flag
# it never stops the VM; it prints the one step that does.
#
#   0. The external IP becomes a reserved static address, in place. An
#      ephemeral IP is released on stop, and the domain's A record would then
#      point at nothing. Promoting it changes nothing on the wire.
#   1. A bucket in the VM's region: uniform access, public access prevented,
#      and ops/gcs-lifecycle.json (daily/ kept 90 days, weekly/ 365).
#   2. A dedicated service account for the VM: write logs and metrics (the Ops
#      Agent), create and read backup objects, and nothing else. In particular
#      it cannot delete or overwrite a backup: the lifecycle rules do the
#      deleting, so a compromised VM cannot take its own backups with it.
#   3. The disk snapshot schedule goes from 14 to 90 days of daily snapshots.
#   4. (--switch-service-account) Snapshot the disk, stop the VM, attach the
#      account, start it. A few minutes of downtime: GCE only changes a VM's
#      service account or scopes while it is stopped, and the default scopes
#      give storage read-only.
set -euo pipefail

PROJECT="${PROJECT:?set PROJECT to the GCP project id}"
REGION="${REGION:-asia-south1}"
ZONE="${ZONE:-asia-south1-b}"
VM="${VM:-ceynex}"
DISK="${DISK:-ceynex}"
BUCKET="${BUCKET:-$PROJECT-backups}"
SA_NAME="${SA_NAME:-ceynex-vm}"
SA="$SA_NAME@$PROJECT.iam.gserviceaccount.com"
OLD_POLICY="${OLD_POLICY:-default-schedule-1}"
NEW_POLICY="${NEW_POLICY:-ceynex-daily-90d}"
STATIC_IP_NAME="${STATIC_IP_NAME:-ceynex-ip}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
g() { gcloud --project "$PROJECT" --quiet "$@"; }

# --- 0. static external IP ------------------------------------------------------
ip=$(g compute instances describe "$VM" --zone "$ZONE" \
       --format='value(networkInterfaces[0].accessConfigs[0].natIP)')
if g compute addresses describe "$STATIC_IP_NAME" --region "$REGION" >/dev/null 2>&1; then
  echo "0. static IP $STATIC_IP_NAME already reserved"
else
  g compute addresses create "$STATIC_IP_NAME" --region "$REGION" --addresses "$ip"
  echo "0. reserved $ip as $STATIC_IP_NAME (was ephemeral)"
fi

# --- 1. bucket --------------------------------------------------------------------
if ! g storage buckets describe "gs://$BUCKET" >/dev/null 2>&1; then
  g storage buckets create "gs://$BUCKET" --location "$REGION" \
    --uniform-bucket-level-access --public-access-prevention
fi
g storage buckets update "gs://$BUCKET" --lifecycle-file "$HERE/ops/gcs-lifecycle.json"
echo "1. gs://$BUCKET ready, lifecycle applied"

# --- 2. service account -------------------------------------------------------------
if ! g iam service-accounts describe "$SA" >/dev/null 2>&1; then
  g iam service-accounts create "$SA_NAME" \
    --display-name "CeyNex VM: logs, metrics, backup upload"
fi
for role in roles/logging.logWriter roles/monitoring.metricWriter; do
  g projects add-iam-policy-binding "$PROJECT" --member "serviceAccount:$SA" \
    --role "$role" --condition=None >/dev/null
done
# objectCreator can write new objects but not delete or overwrite them;
# objectViewer lets backup.sh read back what it uploaded to confirm it.
for role in roles/storage.objectCreator roles/storage.objectViewer; do
  g storage buckets add-iam-policy-binding "gs://$BUCKET" --member "serviceAccount:$SA" \
    --role "$role" >/dev/null
done
echo "2. $SA has its roles"

# --- 3. 90-day snapshot schedule ------------------------------------------------------
if ! g compute resource-policies describe "$NEW_POLICY" --region "$REGION" >/dev/null 2>&1; then
  g compute resource-policies create snapshot-schedule "$NEW_POLICY" --region "$REGION" \
    --max-retention-days 90 --on-source-disk-delete keep-auto-snapshots \
    --daily-schedule --start-time 18:00
fi
attached=$(g compute disks describe "$DISK" --zone "$ZONE" --format='value(resourcePolicies)')
# Detach the old schedule before attaching the new one: a disk takes one
# snapshot schedule at a time. Snapshots it already took keep their own expiry.
case "$attached" in
  *"/$OLD_POLICY"*) g compute disks remove-resource-policies "$DISK" --zone "$ZONE" \
                      --resource-policies "$OLD_POLICY" ;;
esac
case "$attached" in
  *"/$NEW_POLICY"*) ;;
  *) g compute disks add-resource-policies "$DISK" --zone "$ZONE" --resource-policies "$NEW_POLICY" ;;
esac
echo "3. disk $DISK on $NEW_POLICY (daily at 18:00 UTC, kept 90 days)"

# --- 4. the VM's service account (downtime) -------------------------------------------
current=$(g compute instances describe "$VM" --zone "$ZONE" --format='value(serviceAccounts[0].email)')
if [ "$current" = "$SA" ]; then
  echo "4. $VM already runs as $SA"
elif [ "${1:-}" = "--switch-service-account" ]; then
  snap="$VM-pre-sa-switch-$(date -u +%Y%m%d%H%M)"
  g compute disks snapshot "$DISK" --zone "$ZONE" --snapshot-names "$snap"
  g compute instances stop "$VM" --zone "$ZONE"
  g compute instances set-service-account "$VM" --zone "$ZONE" \
    --service-account "$SA" --scopes cloud-platform
  g compute instances start "$VM" --zone "$ZONE"
  echo "4. $VM now runs as $SA (pre-switch snapshot: $snap)"
else
  echo "4. NOT DONE: $VM still runs as $current. Rerun with --switch-service-account in a"
  echo "   maintenance window; it snapshots the disk, stops the VM for a few minutes,"
  echo "   attaches $SA with the cloud-platform scope, and starts it again."
fi
