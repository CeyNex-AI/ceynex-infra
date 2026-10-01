#!/usr/bin/env bash
# SSH through Identity-Aware Proxy only (SAD C4: SSH and RDP open to 0.0.0.0/0).
# Run from a workstation as a project owner:
#
#   PROJECT=<id> IAP_MEMBERS="user:a@example.com,user:b@example.com" bash gcp/03_ssh_via_iap.sh
#   PROJECT=<id> bash gcp/03_ssh_via_iap.sh --close-open-rules
#
# Two steps, deliberately apart, so nobody is locked out:
#
#   1. (always) Allow tcp:22 from Google's IAP range, 35.235.240.0/20, on both
#      networks, and give each IAP_MEMBERS identity the tunnel role plus the
#      read access `gcloud compute ssh` needs. Every existing way in still works.
#      Each person then connects with
#        gcloud compute ssh <vm> --zone <zone> --tunnel-through-iap
#      or, with their key already on the VM, plain ssh through
#        -o ProxyCommand='gcloud compute start-iap-tunnel %h 22 --listen-on-stdin --zone <zone>'
#   2. (--close-open-rules) Delete the rules that open tcp:22 or tcp:3389 to
#      0.0.0.0/0. Run it only once every person who needs the VM has connected
#      through IAP at least once.
set -euo pipefail

PROJECT="${PROJECT:?set PROJECT to the GCP project id}"
NETWORKS="${NETWORKS:-ceynex-vpc default}"
IAP_RANGE="35.235.240.0/20"
IAP_MEMBERS="${IAP_MEMBERS:-}"
OPEN_RULES="${OPEN_RULES:-ssh default-allow-ssh default-allow-rdp}"
g() { gcloud --project "$PROJECT" --quiet "$@"; }

for net in $NETWORKS; do
  rule="$net-allow-ssh-iap"
  if g compute firewall-rules describe "$rule" >/dev/null 2>&1; then
    echo "1. $rule exists"
  else
    g compute firewall-rules create "$rule" --network "$net" --direction INGRESS \
      --action allow --rules tcp:22 --source-ranges "$IAP_RANGE" \
      --description "SSH only through Identity-Aware Proxy (gcp/03_ssh_via_iap.sh)"
    echo "1. created $rule (tcp:22 from $IAP_RANGE on $net)"
  fi
done

IFS=',' read -r -a members <<< "$IAP_MEMBERS"
for member in "${members[@]}"; do
  [ -n "$member" ] || continue
  for role in roles/iap.tunnelResourceAccessor roles/compute.viewer; do
    g projects add-iam-policy-binding "$PROJECT" --member "$member" --role "$role" \
      --condition=None >/dev/null
  done
  echo "1. $member can open an IAP tunnel"
done

if [ "${1:-}" != "--close-open-rules" ]; then
  echo "2. NOT DONE: rules open to 0.0.0.0/0 are still in place. Rerun with"
  echo "   --close-open-rules once everyone has connected through IAP."
  exit 0
fi

for rule in $OPEN_RULES; do
  if ! g compute firewall-rules describe "$rule" >/dev/null 2>&1; then
    echo "2. $rule already gone"
    continue
  fi
  ranges=$(g compute firewall-rules describe "$rule" --format='value(sourceRanges)')
  case ";$ranges;" in
    *"0.0.0.0/0"*) g compute firewall-rules delete "$rule"; echo "2. deleted $rule (was open to 0.0.0.0/0)" ;;
    *) echo "2. kept $rule: not open to the internet ($ranges)" ;;
  esac
done
