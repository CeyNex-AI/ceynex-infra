# ceynex-infra

Deployment and infrastructure for [CeyNex](https://github.com/CeyNex-AI) — a
multi-agent decision intelligence platform for Sri Lanka's national export
economy. Group 07, Project P16, CS3501, University of Moratuwa.

Three GCP VMs in one VPC (`asia-south1-a`), one tier each. Only the frontend is
publicly reachable; the backend and database tiers are protected by source-tag
firewall rules rather than address ranges, which is what stops them from being
reachable from the internet even by accident.

```
                    ┌──────────────────────────────────────────┐
  browser  ──http──▶│ frontend  tier-frontend   10.160.0.2  :80│  ← the only public VM
                    └──────────────────┬───────────────────────┘
                                       │ tcp:8000, source-tags=tier-frontend
                    ┌──────────────────▼───────────────────────┐
                    │ backend   tier-backend    10.160.0.3     │  FastAPI + LangGraph graph
                    └──────────────────┬───────────────────────┘
                                       │ tcp:5432,7474,7687,6379, source-tags=tier-backend
                    ┌──────────────────▼───────────────────────┐
                    │ database  tier-database   10.160.0.4     │  Postgres · Neo4j · Redis
                    └──────────────────────────────────────────┘
```

## Layout

| Path | What |
|---|---|
| `gcp/00_install_docker.sh` | Docker CE from the official Debian repo. Run once per VM. |
| `gcp/01_firewall_setup.sh` | Instance tags plus the four VPC rules. Fill `VPC_NAME` and `YOUR_SSH_IP` first. |
| `database/` | Postgres 18, Neo4j 5.26 (+APOC), Redis 8 |
| `backend/` | The API image and its compose. Builds from `ceynex-contracts` + `ceynex-core`. |
| `frontend/` | VM-side wiring only — the web app is M3's, see `frontend/README.md` |
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
