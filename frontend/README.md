# frontend VM

The only publicly reachable VM. Serves the React app on port 80 and is the only
thing allowed to talk to the backend VM on port 8000.

## Status: not deployable yet

`docker-compose.yml` here declares `build: .`, but **there is no Dockerfile in
this directory and there is not meant to be one yet.** The web application
(`web/`, Vite + React + Tailwind) is M3 Fernando's deliverable per the ownership
table in `ceynex-core/CLAUDE.md`. This directory holds the VM-side wiring that
will run it, nothing more.

When M3's `web/` lands, whoever adds the Dockerfile should know about two traps
already visible in the compose file:

1. **`API_BASE_URL` as a container env var does nothing to a static build.**
   Vite inlines `VITE_*` variables at build time. A runtime environment variable
   on an already-built bundle is never read. Either pass it as a build arg, or
   drop it and use a same-origin path.

2. **The browser cannot reach `http://10.160.0.3:8000`.** That is a VPC-internal
   address; the backend VM has no external IP, by design. A bundle that fetches
   it directly fails for every user. The frontend VM needs to proxy `/api` to the
   backend itself — an nginx `location /api { proxy_pass ...; }` in front of the
   static build is the smallest thing that works, and it keeps the API
   same-origin so no CORS configuration is needed either.

Until then, deploy the database and backend VMs only; the API is verified with
`curl` from the frontend VM (see `../RUNBOOK.md`).
