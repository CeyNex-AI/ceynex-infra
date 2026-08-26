# CeyNex frontend — static Vite/React build served by nginx, which reverse-
# proxies /api to the backend VM. The browser never talks to the backend's
# VPC-internal IP directly (see README.md's two traps: VITE_* env vars are
# baked into the JS bundle at build time, and 10.160.0.3 isn't reachable from
# outside the VPC at all) — this Dockerfile only needs to know the backend's
# internal IP at container *start*, via nginx's own envsubst templating, which
# never touches client-side JS.
#
# Build context is the two repos as siblings, matching backend/Dockerfile's
# convention. From a checkout of https://github.com/CeyNex-AI/ceynex-infra
# sitting beside ceynex-web:
#
#   docker build -f ceynex-infra/frontend/Dockerfile -t ceynex-web /ml/CeyNex

FROM node:22-alpine AS build

WORKDIR /build
COPY ceynex-web/package.json ceynex-web/package-lock.json ./
RUN npm ci
COPY ceynex-web/ ./
RUN npm run build


FROM nginx:1.27-alpine

COPY --from=build /build/dist /usr/share/nginx/html
COPY ceynex-infra/frontend/nginx.conf.template /etc/nginx/templates/default.conf.template

EXPOSE 80

# 127.0.0.1, not localhost: /etc/hosts resolves localhost to ::1 first,
# but nginx only binds 0.0.0.0:80 (IPv4) -- wget hit a closed IPv6 socket
# and never fell back, so this reported unhealthy from boot regardless of
# whether the app actually worked.
HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=5 \
  CMD wget -qO- http://127.0.0.1/ >/dev/null || exit 1
