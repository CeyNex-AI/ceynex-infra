# CeyNex backend — FastAPI + the LangGraph orchestration graph (SAD 7, Web/API
# Server Node). Runs on the backend VM, which has no external IP; only the
# frontend VM can reach port 8000 (see gcp/01_firewall_setup.sh).
#
# Build context is the two source repos, not this directory. From a checkout of
# https://github.com/CeyNex-AI/ceynex-infra sitting beside the others:
#
#   docker build -f ceynex-infra/backend/Dockerfile -t ceynex-api /ml/CeyNex
#
# The context needs ceynex-contracts/ and ceynex-core/ as siblings because
# `ceynex` is a namespace package split across both distributions.

FROM python:3.12-slim AS builder

# psycopg[binary] and pyarrow ship wheels; lightgbm needs libgomp at runtime.
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY ceynex-contracts/ ./ceynex-contracts/
COPY ceynex-core/ ./ceynex-core/

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
RUN pip install --no-cache-dir --upgrade pip \
 && pip install --no-cache-dir ./ceynex-contracts \
 && pip install --no-cache-dir ./ceynex-core


FROM python:3.12-slim

# libgomp1 is lightgbm's only shared-library dependency. curl is here purely so
# the compose healthcheck works — python:3.12-slim does not ship it, and the
# original healthcheck failed for that reason alone.
RUN apt-get update \
 && apt-get install -y --no-install-recommends libgomp1 curl \
 && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# Config the app reads at runtime but that is not packaged: elasticity
# assumptions (SRS 3.1.5) and LLM model ids (config/llm.yaml, kept out of code
# so cost can be traded against quality without a rebuild).
WORKDIR /app
COPY ceynex-core/config/ ./config/

# Never run as root; the app writes only to the LLM cache and the model registry.
RUN useradd --system --create-home --uid 10001 ceynex \
 && mkdir -p /app/.cache /app/models /app/mlruns \
 && chown -R ceynex:ceynex /app
USER ceynex

EXPOSE 8000

HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=5 \
  CMD curl -fsS http://localhost:8000/health || exit 1

# SRS 3.4.2 wants 50 concurrent users; FastAPI's async handling is the basis for
# that, so keep the worker count low and let async do the work rather than
# forking processes that each hold their own Neo4j pool.
CMD ["uvicorn", "ceynex.api.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "2"]
