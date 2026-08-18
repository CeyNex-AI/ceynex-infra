#!/usr/bin/env bash
# VPC firewall for the three CeyNex tiers.
#
# Run from Cloud Shell, or local gcloud authenticated to the project. Idempotent:
# every rule is created only if it does not already exist, so re-running after a
# partial run is safe.
#
# Verified against the live project on 2026-08-18. If any of these stop matching,
# the deployment breaks in ways that look like application bugs:
#
#   project   ceynex
#   network   ceynex-dev        (NOT the "default" network — default-allow-internal
#                                lives there and does not apply to these VMs)
#   zone      asia-south1-c     (the runbook previously said -a)
#   instances ceynex-frontend / ceynex-backend / ceynex-database
#
# Check them with:
#   gcloud compute instances list --format="table(name,zone,networkInterfaces[0].network.basename())"

set -euo pipefail

PROJECT="${PROJECT:-ceynex}"
VPC_NAME="${VPC_NAME:-ceynex-dev}"
ZONE="${ZONE:-asia-south1-c}"

FRONTEND_VM="${FRONTEND_VM:-ceynex-frontend}"
BACKEND_VM="${BACKEND_VM:-ceynex-backend}"
DATABASE_VM="${DATABASE_VM:-ceynex-database}"

# Restricting SSH is opt-in, because getting it wrong locks the whole team out of
# every VM at once. Set it deliberately:
#   YOUR_SSH_IP="$(curl -s ifconfig.me)/32" ./01_firewall_setup.sh
# Leave empty and step 2 is skipped with a warning.
YOUR_SSH_IP="${YOUR_SSH_IP:-}"

rule_exists() {
  gcloud compute firewall-rules describe "$1" --project="$PROJECT" >/dev/null 2>&1
}

echo "== Step 1: Tag the VMs so firewall rules can target them by role =="
# Every rule below targets a tag, so an untagged VM is matched by nothing and all
# its inbound traffic is dropped. This step is not optional.
gcloud compute instances add-tags "$FRONTEND_VM" --project="$PROJECT" --zone="$ZONE" --tags=tier-frontend
gcloud compute instances add-tags "$BACKEND_VM"  --project="$PROJECT" --zone="$ZONE" --tags=tier-backend
gcloud compute instances add-tags "$DATABASE_VM" --project="$PROJECT" --zone="$ZONE" --tags=tier-database

echo "== Step 2: SSH — only your IP(s) =="
if [[ -z "$YOUR_SSH_IP" ]]; then
  echo "   SKIPPED: YOUR_SSH_IP is not set."
  echo "   The project currently allows tcp:22 from 0.0.0.0/0. To close that:"
  echo "     YOUR_SSH_IP=\"\$(curl -s ifconfig.me)/32\" $0"
  echo "   Then delete the open rule:  gcloud compute firewall-rules delete ceynex-dev-allow-ssh"
  echo "   Add every team member's IP before deleting it, or they lose access."
elif rule_exists allow-ssh-team; then
  echo "   allow-ssh-team already exists — leaving it alone"
else
  gcloud compute firewall-rules create allow-ssh-team \
    --project="$PROJECT" \
    --network="$VPC_NAME" \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=tcp:22 \
    --source-ranges="$YOUR_SSH_IP" \
    --target-tags=tier-frontend,tier-backend,tier-database
fi

echo "== Step 3: Public HTTP/HTTPS — frontend only =="
if rule_exists allow-web-frontend; then
  echo "   allow-web-frontend already exists — leaving it alone"
else
  gcloud compute firewall-rules create allow-web-frontend \
    --project="$PROJECT" \
    --network="$VPC_NAME" \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=tcp:80,tcp:443 \
    --source-ranges=0.0.0.0/0 \
    --target-tags=tier-frontend
fi

echo "== Step 4: Backend API — reachable only from frontend's tag =="
if rule_exists allow-backend-from-frontend; then
  echo "   allow-backend-from-frontend already exists — leaving it alone"
else
  gcloud compute firewall-rules create allow-backend-from-frontend \
    --project="$PROJECT" \
    --network="$VPC_NAME" \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=tcp:8000 \
    --source-tags=tier-frontend \
    --target-tags=tier-backend
fi

echo "== Step 5: Database ports — reachable only from backend's tag =="
# 5432 = Postgres, 7474+7687 = Neo4j (HTTP browser + Bolt), 6379 = Redis
if rule_exists allow-db-from-backend; then
  echo "   allow-db-from-backend already exists — leaving it alone"
else
  gcloud compute firewall-rules create allow-db-from-backend \
    --project="$PROJECT" \
    --network="$VPC_NAME" \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=tcp:5432,tcp:7474,tcp:7687,tcp:6379 \
    --source-tags=tier-backend \
    --target-tags=tier-database
fi

echo "== Step 6: Verify =="
gcloud compute firewall-rules list --project="$PROJECT" \
  --format="table(name,network,direction,sourceRanges.list(),sourceTags.list(),targetTags.list(),allowed[].map().firewall_rule().list())"

echo ""
echo "Done. Sanity check before moving on:"
echo "  - tcp:22 and tcp:3389 should NOT be open to 0.0.0.0/0. As of 2026-08-18"
echo "    ceynex-dev-allow-ssh and ceynex-dev-allow-rdp both are. RDP on a Linux VM"
echo "    serves no purpose at all and can simply be deleted."
echo "  - allow-web-frontend should be the only rule with 0.0.0.0/0"
echo "  - allow-backend-from-frontend and allow-db-from-backend should have NO source-ranges,"
echo "    only source-tags (this is what keeps backend/database off the public internet)"
