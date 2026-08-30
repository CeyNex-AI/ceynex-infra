#!/usr/bin/env bash
# Generate the self-signed cert nginx serves on :443.
#
# docker-compose.yml bind-mounts ./certs into the container read-only and
# nginx.conf.template names fullchain.pem/privkey.pem, so nginx will not start
# until both exist. That made the TLS change a site-down deploy rather than an
# HTTP->HTTPS one, which is why this is a script and not a line of README prose.
#
# No public CA issues certs for a bare IP, so this is self-signed and browsers
# will warn. Once a domain points at this VM, replace these two files with
# certbot's and add a renewal timer -- nginx.conf.template needs no change.
#
#   ./make-cert.sh                  # SAN = this VM's external IP, auto-detected
#   ./make-cert.sh 35.200.228.142   # SAN = the IP you name
#   ./make-cert.sh --force          # overwrite an existing cert
set -euo pipefail

cd "$(dirname "$0")"

FORCE=0
IP=""
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -*) echo "unknown flag: $arg" >&2; exit 2 ;;
    *) IP="$arg" ;;
  esac
done

if [[ -z "$IP" ]]; then
  # GCP metadata first (authoritative, no egress); fall back to an echo service.
  IP=$(curl -fsS -m 5 -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip" \
    2>/dev/null || curl -fsS -m 5 https://ifconfig.me 2>/dev/null || true)
fi

if [[ -z "$IP" ]]; then
  echo "could not determine the external IP; pass it: ./make-cert.sh <ip>" >&2
  exit 1
fi

if [[ -f certs/fullchain.pem && $FORCE -eq 0 ]]; then
  echo "certs/fullchain.pem exists; re-run with --force to replace it."
  openssl x509 -in certs/fullchain.pem -noout -subject -enddate -ext subjectAltName
  exit 0
fi

mkdir -p certs
openssl req -x509 -newkey rsa:4096 -nodes -days 365 \
  -keyout certs/privkey.pem \
  -out certs/fullchain.pem \
  -subj "/CN=$IP/O=CeyNex/OU=Group 07 P16/C=LK" \
  -addext "subjectAltName=IP:$IP" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
  -addext "extendedKeyUsage=serverAuth" 2>/dev/null

# The container reads these as root; the key must not be world-readable here.
chmod 600 certs/privkey.pem
chmod 644 certs/fullchain.pem

echo "wrote certs/fullchain.pem and certs/privkey.pem"
openssl x509 -in certs/fullchain.pem -noout -subject -enddate -ext subjectAltName
