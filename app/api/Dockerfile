FROM python:3.12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py schema.sql ./

# NOTE: no USER directive here — the actual runtime UID:GID is supplied by
# Compose's `user: "${PF2P_SVC_UID}:${PF2P_SVC_GID}"`, verified against the
# real pf2p-svc account at setup time, not baked into the image.

EXPOSE 8420
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8420"]
