#!/usr/bin/env bash
# Run this from Cloud Shell (or local gcloud, authenticated to your project).
# Replace YOUR_VPC_NAME and YOUR_SSH_IP before running.

set -euo pipefail

VPC_NAME="YOUR_VPC_NAME"          # e.g. "ceynex-vpc" — check with: gcloud compute networks list
YOUR_SSH_IP="YOUR_HOME_IP/32"     # e.g. "123.45.67.89/32" — check with: curl -s ifconfig.me

echo "== Step 1: Tag the VMs so firewall rules can target them by role =="
gcloud compute instances add-tags frontend --zone=asia-south1-a --tags=tier-frontend
gcloud compute instances add-tags backend  --zone=asia-south1-a --tags=tier-backend
gcloud compute instances add-tags database --zone=asia-south1-a --tags=tier-database

echo "== Step 2: SSH — only your IP(s), only to VMs you actually need shell on =="
# If you SSH into all three, add all three target-tags. If only via `frontend` as a
# jump host, narrow this further.
gcloud compute firewall-rules create allow-ssh-team \
  --network="$VPC_NAME" \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:22 \
  --source-ranges="$YOUR_SSH_IP" \
  --target-tags=tier-frontend,tier-backend,tier-database

echo "== Step 3: Public HTTP/HTTPS — frontend only =="
gcloud compute firewall-rules create allow-web-frontend \
  --network="$VPC_NAME" \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:80,tcp:443 \
  --source-ranges=0.0.0.0/0 \
  --target-tags=tier-frontend

echo "== Step 4: Backend API — reachable only from frontend's tag =="
gcloud compute firewall-rules create allow-backend-from-frontend \
  --network="$VPC_NAME" \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:8000 \
  --source-tags=tier-frontend \
  --target-tags=tier-backend

echo "== Step 5: Database ports — reachable only from backend's tag =="
# 5432 = Postgres, 7474+7687 = Neo4j (HTTP browser + Bolt), 6379 = Redis
gcloud compute firewall-rules create allow-db-from-backend \
  --network="$VPC_NAME" \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:5432,tcp:7474,tcp:7687,tcp:6379 \
  --source-tags=tier-backend \
  --target-tags=tier-database

echo "== Step 6: Verify =="
gcloud compute firewall-rules list --format="table(name,direction,sourceRanges.list(),sourceTags.list(),targetTags.list(),allowed[].map().firewall_rule().list())"

echo ""
echo "Done. Sanity check before moving on:"
echo "  - allow-ssh-team should list your IP only, not 0.0.0.0/0"
echo "  - allow-web-frontend should be the only rule with 0.0.0.0/0"
echo "  - allow-backend-from-frontend and allow-db-from-backend should have NO source-ranges,"
echo "    only source-tags (this is what keeps backend/database off the public internet)"
