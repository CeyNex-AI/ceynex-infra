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

HTTPS is served on 443 with a **self-signed** cert
(`certs/fullchain.pem`/`certs/privkey.pem`, SAN = the VM's external IP). Port 80
redirects to 443. Browsers will show an untrusted-certificate warning — expected,
since no public CA issues certs for bare IP addresses.

**Generate the cert before the first `docker compose up`**, on the VM:

```bash
cd ~/ceynex/ceynex-infra/frontend
./make-cert.sh            # SAN = this VM's external IP, from GCP metadata
```

`certs/` is gitignored and nginx will not start without both files in it, so
skipping this step takes the site down rather than upgrading it. The script is
idempotent — it refuses to overwrite an existing cert unless given `--force`.

**Once a domain is pointed at this VM's external IP**, replace the self-signed
setup with a real one:

```bash
sudo apt-get install -y certbot python3-certbot-nginx   # or run certbot in a
                                                          # sidecar container
# then either let certbot's nginx plugin rewrite the config, or manually
# swap certs/fullchain.pem + certs/privkey.pem for the certbot-issued files
# and add a renewal cron/systemd timer (`certbot renew`).
```

No firewall change needed — `allow-web-frontend` already opens tcp:80 and
tcp:443 to `0.0.0.0/0`.
