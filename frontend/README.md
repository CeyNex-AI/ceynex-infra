# frontend VM

The only publicly reachable VM. Serves the React app (`ceynex-web`, M3
Fernando's deliverable) on port 80/443 via nginx, and is the only VM allowed
to talk to the backend VM on port 8000.

## Status: deployed

`Dockerfile` builds `ceynex-web/` (Vite + React + Tailwind) as a static bundle
and serves it with nginx, which reverse-proxies `/api/` and `/health` to the
backend over the VPC (`nginx.conf.template`, `BACKEND_INTERNAL_IP`). Build
context is the two repos as siblings, same convention as `backend/Dockerfile`:
`ceynex-infra` sitting beside `ceynex-web`.

Two traps this setup avoids:

1. **`BACKEND_INTERNAL_IP` is read only by nginx's startup `envsubst`, never by
   client JS.** A `VITE_*` var would get inlined into the bundle at build time
   instead — wrong tool for a value that can change per-deploy.
2. **The browser cannot reach `http://10.160.0.3:8000` directly** (VPC-internal,
   no external IP by design). `location /api/` on this nginx is what makes the
   API reachable at all, same-origin, no CORS needed.

## TLS

The site is **https://ceynex.cc** (and `www.ceynex.cc`). nginx terminates TLS
on 443 with a **Let's Encrypt** cert (`certs/fullchain.pem`/`certs/privkey.pem`,
SAN = `ceynex.cc`, `www.ceynex.cc`); port 80 redirects to 443. The bare IP still
answers, but with a name-mismatch warning — link to the domain, not the IP.

No firewall change was needed — `allow-web-frontend` already opens tcp:80 and
tcp:443 to `0.0.0.0/0`.

### DNS

`ceynex.cc` is registered with Cloudflare, which is also its DNS. Two `A`
records, `@` and `www`, point at the VM's external IP, both **DNS only** (grey
cloud). No `AAAA` — the VM has no IPv6.

Keep them DNS only. `ceynex/api/rate_limit.py::client_ip` (in `ceynex-core`)
trusts `X-Real-IP`, which this nginx sets to `$remote_addr`. Proxied through
Cloudflare, that becomes a Cloudflare edge address, so every anonymous caller
behind the same edge shares one rate-limit bucket. Turning the orange cloud on
first needs `set_real_ip_from <Cloudflare ranges>` + `real_ip_header
CF-Connecting-IP` in `nginx.conf.template`.

### Issuing the cert

Issued with a **DNS-01** challenge through the Cloudflare API, using the
`certbot/dns-cloudflare` image. Nothing touches nginx or port 80, so issuing and
renewing never need nginx stopped or its config changed. On the VM:

- `~/letsencrypt/cloudflare.ini` (mode 600) holds one line,
  `dns_cloudflare_api_token = …` — a token from Cloudflare's "Edit zone DNS"
  template, scoped to the `ceynex.cc` zone only.
- `~/letsencrypt/{etc,lib}` is certbot's state (root-owned; the container runs
  as root).
- `certs/*.pem` are **copies** of `~/letsencrypt/etc/live/ceynex.cc/*.pem`, not
  symlinks — those point into `archive/`, which is outside the bind mount.

```bash
docker run --rm \
  -v ~/letsencrypt/etc:/etc/letsencrypt \
  -v ~/letsencrypt/lib:/var/lib/letsencrypt \
  -v ~/letsencrypt/cloudflare.ini:/cloudflare.ini:ro \
  certbot/dns-cloudflare certonly --non-interactive \
  --dns-cloudflare --dns-cloudflare-credentials /cloudflare.ini \
  --dns-cloudflare-propagation-seconds 30 \
  -d ceynex.cc -d www.ceynex.cc \
  --email <owner-email> --agree-tos --no-eff-email

cd ~/ceynex/ceynex-infra/frontend
sudo cp -L ~/letsencrypt/etc/live/ceynex.cc/fullchain.pem certs/fullchain.pem
sudo cp -L ~/letsencrypt/etc/live/ceynex.cc/privkey.pem  certs/privkey.pem
docker exec ceynex-web nginx -t && docker exec ceynex-web nginx -s reload
```

No rebuild or restart: `certs/` is bind-mounted, so a reload picks up the new
files.

### Renewal

Let's Encrypt certs last 90 days. `~/renew-cert.sh` runs from **root's**
crontab daily at 03:30 UTC (after the 02:00 backup) and logs to
`/var/log/ceynex-cert-renew.log`. `certbot renew` is a no-op until a cert is
within 30 days of expiry, and the script only copies and reloads when the cert
actually changed:

```bash
#!/usr/bin/env bash
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
LE=/home/<vm-user>/letsencrypt
CERTS=/home/<vm-user>/ceynex/ceynex-infra/frontend/certs
LIVE=$LE/etc/live/ceynex.cc

docker run --rm \
  -v $LE/etc:/etc/letsencrypt -v $LE/lib:/var/lib/letsencrypt \
  -v $LE/cloudflare.ini:/cloudflare.ini:ro \
  certbot/dns-cloudflare renew --quiet

if ! cmp -s $LIVE/fullchain.pem $CERTS/fullchain.pem; then
  cp -L $LIVE/fullchain.pem $CERTS/fullchain.pem
  cp -L $LIVE/privkey.pem  $CERTS/privkey.pem
  docker exec ceynex-web nginx -t
  docker exec ceynex-web nginx -s reload
fi
```

```
30 3 * * * /home/<vm-user>/renew-cert.sh >> /var/log/ceynex-cert-renew.log 2>&1
```

To check that renewal would succeed without touching the live cert, run the
same `docker run` with `renew --dry-run` (it uses Let's Encrypt's staging CA).

### HSTS

`nginx.conf.template` sends `Strict-Transport-Security: max-age=31536000;
includeSubDomains`. Now that the cert is valid, browsers enforce it: for a
year, `ceynex.cc` **and every subdomain** is HTTPS-only. Any subdomain added
later must serve a valid cert from day one.

### Fresh VM / fallback: `make-cert.sh`

`certs/` is gitignored and nginx will not start without both files in it, so a
fresh VM needs a cert before its first `docker compose up`. Either issue the
Let's Encrypt cert first (DNS-01 doesn't need nginx running), or bootstrap with
a self-signed one and replace it afterwards:

```bash
cd ~/ceynex/ceynex-infra/frontend
./make-cert.sh            # self-signed, SAN = this VM's external IP
```

The script refuses to overwrite an existing cert unless given `--force` — on the
live VM, `--force` would replace the Let's Encrypt cert with a self-signed one.
