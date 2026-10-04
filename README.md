# ceynex-infra

Deployment and operations for **CeyNex**, a multi-agent decision intelligence platform for Sri Lanka's export economy. This repo holds:

- the Docker images and Compose projects;
- the nginx front door;
- the Google Cloud setup scripts;
- nightly backups and the restore drill;
- the monthly data refresh;
- uptime monitoring and credential rotation.

Group 07, Project P16, CS3501 Data Science and Engineering Project, University of Moratuwa.
Live system: <https://ceynex.cc>.

---

## Where it fits

| Repo | Built into |
|---|---|
| [`ceynex-contracts`](https://github.com/CeyNex-AI/ceynex-contracts) + [`ceynex-core`](https://github.com/CeyNex-AI/ceynex-core) | `ceynex-api` image (`backend/Dockerfile`) |
| [`ceynex-web`](https://github.com/CeyNex-AI/ceynex-web) | `ceynex-web` image (`frontend/Dockerfile`, nginx) |
| **`ceynex-infra`** (this repo) | Compose projects, scripts and runbooks |

All the images build from repos checked out **side by side**. Each compose file uses `context: ../..`:

```
~/ceynex/
  ceynex-contracts/
  ceynex-core/
  ceynex-web/
  ceynex-infra/      <- run compose from here
```

## Production

Since 2026-09-09, production has been **one Google Compute Engine VM** (`ceynex`, zone `asia-south1-b`) serving <https://ceynex.cc>. Three compose projects run on it (`db` from `database/`, then `backend` and `frontend`), and they share one external Docker network, `ceynex`.

```
  browser ──https──▶ ceynex-web  (nginx 1.27, :80 → :443, Let's Encrypt)
                        │ /api/  /health      by container name on the `ceynex` network
                        ▼
                     ceynex-api  (FastAPI + LangGraph, python:3.12-slim, 2 uvicorn workers)
                        │ by container name
                        ▼
   ceynex-postgres (18.4) · ceynex-neo4j (5.26 + APOC) · ceynex-redis (8.0) · ceynex-qdrant (1.17)
   host ports 5432 7474 7687 6379 6333 8000 bound to 127.0.0.1 only
```

| Container | Image | Memory cap | Purpose |
|---|---|---|---|
| `ceynex-web` | `ceynex-web:latest` (node 22 build, nginx 1.27) | 256m | Static React app, TLS, reverse proxy to the API |
| `ceynex-api` | `ceynex-api:latest` | 4g | The API, orchestrator and agents |
| `ceynex-postgres` | `postgres:18.4` | 1g | `fact_trade` and the other tables, users, chat, audit log |
| `ceynex-neo4j` | `neo4j:5.26-community` | 5g | Trade knowledge graph |
| `ceynex-redis` | `redis:8.0` (password protected) | 512m | Shared rate-limit windows, chat turn mirrors |
| `ceynex-qdrant` | `qdrant/qdrant:v1.17.1` | 1g | Policy passages (`ceynex_policy`) and news (`ceynex_news`) |

### Network and access

- **Public ports:** 80 (redirects to HTTPS) and 443. Cloudflare DNS points `ceynex.cc` at the VM's static IP. nginx terminates TLS with a Let's Encrypt certificate issued through a DNS challenge.
- **Datastores and the API** listen on 127.0.0.1 only. This matters because Docker-published ports bypass the host firewall.
- **SSH** is key-only from anywhere: `sshd` refuses passwords and root login. The firewall rule is `ceynex-vpc-allow-ssh` (tcp:22, VMs tagged `ssh`). It was reopened on 2026-10-02 after a period of IAP-only access. IAP still works too (`gcp/03_ssh_via_iap.sh`), and `--close-open-rules` goes back to IAP-only.

### Operations

| What | How | When |
|---|---|---|
| Logical backup of every datastore, model registry, dataset and encrypted config to Cloud Storage | `ops/backup.sh` | Daily 02:00 UTC, kept 90 days. Sunday runs kept a year. |
| Disk snapshot | snapshot schedule `ceynex-daily-90d` | Daily, kept 90 days |
| Restore drill: newest backup into a throwaway stack, every count checked | `ops/restore-drill.sh` | First production drill passed 2026-10-01; log in `ops/RESTORE.md` |
| Data refresh: Pink Sheet fetch, re-ingest of network-backed sources, graph flows | `ops/refresh.sh` | Monthly, the 2nd at 04:30 UTC |
| Uptime checks on `/health` (availability and stale sources) and a certificate-expiry alert, by e-mail | `gcp/04_monitoring_setup.sh` | Continuous |
| Rotate database, Redis and JWT credentials | `ops/rotate-secrets.sh` | In a maintenance window |

The VM's service account can create objects in the backup bucket but can neither delete nor overwrite them, so a compromised VM cannot remove its own backups. The passphrase for the encrypted config archive is kept in the team password manager, not on the VM.

## Layout

| Path | What |
|---|---|
| `database/` | Compose for PostgreSQL, Neo4j (+APOC), Redis and Qdrant; `.env.example` |
| `backend/` | `Dockerfile` (two-stage, installs `ceynex-contracts` then `ceynex-core`), compose, `.env.example` |
| `frontend/` | `Dockerfile` (builds `ceynex-web`, serves with nginx), `nginx.conf.template`, `make-cert.sh`, compose; see `frontend/README.md` |
| `gcp/00_install_docker.sh` | Docker CE from the official Debian repo. Run once per VM. |
| `gcp/01_firewall_setup.sh` | Instance tags and VPC rules (written for the three-VM layout) |
| `gcp/02_backup_setup.sh` | Static IP, backup bucket and lifecycle (`ops/gcs-lifecycle.json`), VM service account, snapshot schedule |
| `gcp/03_ssh_via_iap.sh` | IAP SSH: opens 22 to the IAP range and grants the tunnel role; `--close-open-rules` removes rules open to 0.0.0.0/0 |
| `gcp/04_monitoring_setup.sh` | Uptime checks and alert policies |
| `ops/backup.sh`, `ops/manifest.py`, `ops/lib-counts.sh` | Nightly backup and the row, node and point counts it records |
| `ops/restore-drill.sh`, `ops/restore-drill.compose.yml` | Restore into an isolated stack and compare counts |
| `ops/RESTORE.md` | Retention, step-by-step restore, drill log |
| `ops/refresh.sh` | Monthly refresh |
| `ops/rotate-secrets.sh` | Credential rotation |
| `ops/crontab.example` | The two cron entries (backup, refresh) |
| `DEPLOY_ORDER.md` | Full deployment sequence for both layouts |

## Deploying

The full sequence is in [`DEPLOY_ORDER.md`](DEPLOY_ORDER.md) under "Single VM". In short:

```bash
# once per machine
docker network create ceynex

# each .env from its .env.example; for one VM:
#   database/.env  DB_PUBLISH_ADDR=127.0.0.1  COMPOSE_PROJECT_NAME=db
#   backend/.env   POSTGRES_HOST=ceynex-postgres NEO4J_HOST=ceynex-neo4j
#                  REDIS_HOST=ceynex-redis QDRANT_HOST=ceynex-qdrant API_PUBLISH_ADDR=127.0.0.1
#   frontend/.env  BACKEND_INTERNAL_IP=ceynex-api

(cd database && docker compose -p db up -d)
(cd backend  && docker compose build && docker compose up -d)
(cd frontend && docker compose build && docker compose up -d)

# first deploy only, inside ceynex-api: schema, data, graph, models
docker exec ceynex-api python -m ceynex.data.bootstrap
docker exec ceynex-api python -m ceynex.data.pipeline --sources all
docker exec ceynex-api python -m ceynex.kg.load --schema --agreements --apparel --flows --policy
```

A routine redeploy is `git pull` in the changed repo, then `docker compose build && docker compose up -d` in its compose directory. Register the forecast models after a fresh deploy (`DEPLOY_ORDER.md` §2b). If you skip this, the forecast agent silently falls back to its drift baseline.

Check the deploy:

```bash
curl -s https://ceynex.cc/health   # {"status":"ok","postgres":true,"neo4j":true,"llm":true,...}
ss -ltn                            # datastore ports and 8000 on 127.0.0.1 only
```

### The original three-VM layout

The same files still reproduce the first layout: `frontend`, `backend` and `database` VMs at `10.160.0.2/.3/.4`, with source-tag firewall rules between them. Leave the single-VM `.env` values unset and the defaults bring it back. `gcp/01_firewall_setup.sh` creates its rules, and `DEPLOY_ORDER.md` describes it from step 0 on.

## Credentials

- Every `.env.example` is tracked, and a filled-in `.env` never is.
- The backend's `POSTGRES_*`, `NEO4J_PASSWORD` and `REDIS_PASSWORD` must match `database/.env` exactly.
- `CEYNEX_JWT_SECRET` signs sessions. Rotating it signs everyone out once.
- `OPENAI_API_KEY` may be left empty. The system then answers with knowledge-graph and forecast figures only and sets `degraded=true`. That is required behaviour, not a broken deploy.
- `OPENROUTER_API_KEY` is the failsafe provider and is optional. Model ids and the spend cap live in `ceynex-core/config/llm.yaml`.
- `TAVILY_API_KEY` is optional. Without it, web search is off.
- `CEYNEX_BOOTSTRAP_ADMIN=email:password` creates the first admin account. Sign-up never grants admin.

## Things that are easy to get wrong

- **Both Python repos must be in the backend build context.** `ceynex` is a namespace package split across `ceynex-contracts` and `ceynex-core`.
- **`postgres:18` wants its volume at `/var/lib/postgresql`**, not `.../data`. Mounting the inner path makes the container exit in a loop with a misleading log message.
- **There is no initdb hook.** The schema lives in `ceynex-contracts` and is applied by `ceynex.data.bootstrap`, because this database is updated in place, not recreated.
- **Compose project names must stay `db`, `backend` and `frontend`.** The volume names derive from them.
- **Rebuilding `ceynex-api` wipes its `/tmp`,** including any evaluation results written there. Copy them out first.
- **`BACKEND_INTERNAL_IP` is read by nginx's startup `envsubst`, never by browser code.** A `VITE_*` variable would be baked into the bundle at build time.
- **Keep the TLS certificate and `.env` files when redeploying.** A redeploy that replaces whole directories must keep them.

## Team

Infrastructure: Thisen Ekanayake (230170B). Front-end image and nginx: Dhinanjaya Fernando (230181J). Team: Senindu Dinapura (230151T). Supervisor: Dr. Chathuranga Hettiarachchi, University of Moratuwa.
