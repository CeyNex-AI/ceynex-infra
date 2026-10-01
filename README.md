# ceynex-infra

Deployment and infrastructure for [CeyNex](https://github.com/CeyNex-AI) — a
multi-agent decision intelligence platform for Sri Lanka's national export
economy. Group 07, Project P16, CS3501, University of Moratuwa.

**Production: one GCP VM** (`ceynex`, zone `asia-south1-b`, since 2026-09-09),
serving https://ceynex.cc. Three compose projects run on it: `db` from
`database/`, `backend` and `frontend`. They share one Docker network, `ceynex`.

```
  browser ──https──▶ ceynex-web (nginx, :80 :443, Let's Encrypt)      ← only 80 and 443 are public
                        │ /api/  /health   (container name, `ceynex` network)
                        ▼
                     ceynex-api (FastAPI + LangGraph, 2 uvicorn workers)
                        │ container names, `ceynex` network
                        ▼
     ceynex-postgres · ceynex-neo4j · ceynex-redis · ceynex-qdrant
     (host ports on 127.0.0.1 only: reachable from the VM itself, never from outside)
```

- **SSH:** Identity-Aware Proxy only (`gcp/03_ssh_via_iap.sh`).
- **Backups:** nightly to GCS, plus 90 days of disk snapshots (`ops/RESTORE.md`).
- **Refresh:** a monthly cron re-ingests the network-backed sources (`ops/refresh.sh`).
- **Monitoring:** uptime checks with email alerts watch availability and stale data (`gcp/04_monitoring_setup.sh`).
- **Deploying:** `DEPLOY_ORDER.md`, "Single VM".

**The original layout, three VMs** (one tier each, `10.160.0.2/.3/.4`, with
source-tag firewall rules between them), still works from the same files. Leave
the single-VM `.env` values unset and the defaults reproduce it;
`gcp/01_firewall_setup.sh` creates its rules. It is described in
`DEPLOY_ORDER.md` from step 0 on.

## Layout

| Path | What |
|---|---|
| `gcp/00_install_docker.sh` | Docker CE from the official Debian repo. Run once per VM. |
| `gcp/01_firewall_setup.sh` | Instance tags plus the four VPC rules. Fill `VPC_NAME` and `YOUR_SSH_IP` first. |
| `database/` | Postgres 18, Neo4j 5.26 (+APOC), Redis 8 |
| `backend/` | The API image and its compose. Builds from `ceynex-contracts` + `ceynex-core`. |
| `frontend/` | VM-side wiring only — the web app is M3's, see `frontend/README.md` |
| `gcp/02_backup_setup.sh` | Off-VM backups: static IP, the backup bucket and its lifecycle, the VM's service account, the 90-day snapshot schedule |
| `gcp/03_ssh_via_iap.sh` | SSH only through Identity-Aware Proxy: opens 22 to the IAP range, grants the tunnel role, then (on request) closes the 0.0.0.0/0 rules |
| `gcp/04_monitoring_setup.sh` | Uptime checks on `/health` (availability, and stale data sources) with email alerts, plus a certificate-expiry alert |
| `ops/refresh.sh` | The monthly data refresh (cron on the 2nd, 04:30 UTC): Pink Sheet fetch, re-ingest, graph flows |
| `ops/backup.sh` | The nightly backup (cron at 02:00 UTC), uploaded to the bucket; `ops/crontab.example` |
| `ops/restore-drill.sh` | Restores the newest backup into a throwaway stack and checks every count |
| `ops/RESTORE.md` | What is kept for how long, how to restore it, and the drill log |
| `DEPLOY_ORDER.md` | The sequence to follow, database first |

## Things that are easy to get wrong here

- **The backend image needs both source repos in its build context.** `ceynex`
  is an implicit namespace package: `ceynex.contracts` comes from one
  distribution and everything else from another. The compose file therefore sets
  `context: ../..` and expects the three repos checked out as siblings.
- **`postgres:18` wants its volume at `/var/lib/postgresql`**, not at
  `.../data`. Mounting the inner path makes the container refuse to adopt the
  directory and exit, over and over, with a long and easily-misread log message.
- **No initdb hook anywhere.** The schema lives in the `ceynex-contracts`
  package and is applied by `make db-init`, because an initdb script only runs
  against a first-boot empty volume and this database gets updated, not
  recreated.
- **`python:3.12-slim` has no `curl`.** The backend healthcheck used it and
  failed for that reason alone; the Dockerfile now installs it.

## Credentials

Every `.env.example` is tracked; no filled-in `.env` ever is. The backend's
`POSTGRES_*`, `NEO4J_PASSWORD` and `REDIS_PASSWORD` must match the database VM's
`.env` exactly — they are the same credentials seen from two machines.

`OPENAI_API_KEY` may be left empty. The system then answers with raw
knowledge-graph and forecast figures and sets `degraded=true`, which is required
behaviour under SRS 3.4.3, not a broken deployment.

`OPENROUTER_API_KEY` (R5 failsafe, tried once if the OpenAI call above fails or
its spend cap is hit) may also be left empty, same reasoning — the model ids
and failsafe config live in `ceynex-core/config/llm.yaml`.
