# Deploy order

Three GCP VMs in one VPC, zone `asia-south1-a`. Only `frontend` has an external
IP; `backend` and `database` are reachable only from inside the VPC, and only in
that order — the firewall rules are source-tag based, not source-range based,
which is what keeps them off the public internet.

```
browser ──http──▶ frontend :80 ──▶ backend :8000 ──▶ database :5432 / :7687 / :6379
 (public)          10.160.0.2       10.160.0.3        10.160.0.4
```

## 0. One-time, from your local machine / Cloud Shell

1. Run `gcp/01_firewall_setup.sh` after filling in `VPC_NAME` and `YOUR_SSH_IP`.
2. Confirm `backend` and `database` have no external IP. If they do, remove it.
3. Note the internal IPs of `backend` and `database`:
   ```bash
   gcloud compute instances describe database --zone=asia-south1-a \
     --format='get(networkInterfaces[0].networkIP)'
   ```

## 1. `database` VM

```bash
scp -r database/ gcp/00_install_docker.sh <user>@<database-ip>:~/ceynex-db/
ssh <user>@<database-ip>
cd ~/ceynex-db
bash 00_install_docker.sh    # then log out and back in, or `newgrp docker`
cp .env.example .env
nano .env                    # real passwords
docker compose up -d
docker compose ps            # all three must reach "healthy", not just "up"
```

The schema is **not** applied here. There is no initdb hook, deliberately: an
initdb script only ever runs against a first-boot empty volume, which is not how
this box gets updated. `make db-init` from `ceynex-core` applies it instead, and
that same command works against a developer's local stack.

> **Upgrading an existing box:** if `ceynex-postgres` is restarting in a loop,
> it is the volume mount. `postgres:18` wants the volume at
> `/var/lib/postgresql`, not `/var/lib/postgresql/data`. This compose file is
> already correct; the container needs its volume recreated to pick it up, which
> destroys whatever is in it. Check first:
> ```bash
> docker compose down
> docker volume rm ceynex-db_postgres_data
> docker compose up -d
> ```

## 2. `backend` VM

The image is built from **two** source repos — `ceynex` is a namespace package
split across `ceynex-contracts` and `ceynex-core` — so this VM gets git clones
rather than an `scp` of one directory.

```bash
ssh <user>@<backend-ip>
bash ~/00_install_docker.sh   # if needed; log out and back in

mkdir -p ~/ceynex && cd ~/ceynex
git clone git@github.com:CeyNex-AI/ceynex-contracts.git
git clone git@github.com:CeyNex-AI/ceynex-core.git
git clone git@github.com:CeyNex-AI/ceynex-infra.git

cd ~/ceynex/ceynex-infra/backend
cp .env.example .env
nano .env                     # DATABASE_INTERNAL_IP + passwords matching step 1
docker compose up -d --build
docker compose logs -f api
```

Then apply the schema and load the graph, once, from inside the running container:

```bash
docker compose exec api python -m ceynex.data.bootstrap   # schema.sql + dim_* seed
docker compose exec api python -m ceynex.kg.load --schema --agreements
```

### 2b. Register the forecast models — easy to miss, and silent when missed

**A fresh backend serves every forecast from the drift baseline until you do
this.** Measured live 2026-09-03: S05 (tea) and S10 (knit apparel) both answered
with *"No registered export-value model for this item yet, so the figures come
from a drift baseline"* while `ceynex-core/docs/EVALUATION.md §3` advertised
5.3% MAPE for tea. Nothing fails and nothing warns — the baseline is a supported
fallback, so an empty registry looks exactly like a working system.

The artifacts cannot arrive with the source. `models/` is git-ignored, excluded
by `backend/Dockerfile.dockerignore`, and excluded from the `--exclude='models'`
update tar in the team deployment doc. The `models_data` volume mounted at
`CEYNEX_MODELS_DIR=/app/models` is the only path in, so build them where they
will live:

```bash
cd ~/ceynex/ceynex-infra/backend
for spec in agriculture:tea agriculture:cinnamon agriculture:rubber \
            apparel:apparel_knit apparel:apparel_woven; do
  docker compose exec -T api python -m eval.backtest \
    --sector "${spec%%:*}" --item "${spec##*:}" --register
done
```

`--register` is what saves the fitted model with its backtest metrics. Do not
drop it: `registry.load_best` ranks on MAPE and **ignores any version without
one**, so an unscored model is registered and then never served.

Confirm all five landed, and that the volume survived:

```bash
docker compose exec api python -c \
  "from ceynex.models.registry import list_models
for m in list_models(): print(m.sector, m.item, m.target, m.version, m.metrics)"
```

Then re-ask a forecast question and check the phrase "drift baseline" is gone:

```bash
curl -fsS -X POST http://localhost:8000/api/query -H 'content-type: application/json' \
  -d '{"query":"Forecast knitted apparel export value for the next two years."}' \
  | grep -c "drift baseline"    # expect 0
```

This needs `fact_trade` and the graph already loaded (steps 1 and 2a) — the
backtest trains on the real series, so an empty database gives you five models
fitted on nothing.

## 3. `frontend` VM

**Not deployable yet** — the web application is M3's deliverable and there is no
Dockerfile in `frontend/`. See `frontend/README.md` for the two traps waiting
there (`VITE_*` build-time inlining, and the browser being unable to reach a
VPC-internal address). Until then, verify the API from this VM with `curl`.

## 4. Verify end to end

```bash
# from the frontend VM — this is the only path that is supposed to work
curl -fsS http://<backend-internal-ip>:8000/health
curl -fsS -X POST http://<backend-internal-ip>:8000/api/query \
  -H 'content-type: application/json' \
  -d '{"query":"which district contributes the largest share of cinnamon exports?"}'
```

If the frontend cannot reach the backend, check that the
`allow-backend-from-frontend` rule's source-tags match the frontend VM's actual
tags:

```bash
gcloud compute instances describe frontend --zone=asia-south1-a --format='get(tags.items)'
```

## Cost discipline

Compute is billed while running; disk still bills while stopped, but that is a
few dollars a month. Running all three 24/7 for a month lands close to or over
the $300 credit at these machine sizes in Mumbai.

```bash
gcloud compute instances stop  frontend backend database --zone=asia-south1-a
gcloud compute instances start frontend backend database --zone=asia-south1-a
```

Neo4j holds the knowledge graph on a named volume, so stopping the VMs does not
lose it. Re-running `make db-init` and `kg-load` after a restart is free anyway —
both are idempotent.
