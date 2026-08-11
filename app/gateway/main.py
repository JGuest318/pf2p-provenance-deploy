"""
PF2P_PROVENANCE Gateway — image tag: pf2p/gateway:0.1.0

Single externally-reachable entry point for Phase 1. Proxies requests to
the internal API service over the pf2p_backend network. Has no direct
filesystem access to the photography archive or the provenance database —
it only ever talks to the API over HTTP.
"""
import os

import httpx
from fastapi import FastAPI, Request, Response

API_INTERNAL_URL = os.environ.get("PF2P_API_INTERNAL_URL", "http://pf2p-provenance-api:8420")

app = FastAPI(title="PF2P Gateway", version="0.1.0")


@app.get("/v1/status")
async def status():
    # Used verbatim by the Compose healthcheck:
    #   CMD curl -sf http://localhost:8421/v1/status
    return {"status": "ok", "service": "pf2p-gateway", "version": "0.1.0"}


@app.api_route("/v1/{path:path}", methods=["GET", "POST"])
async def proxy(path: str, request: Request):
    url = f"{API_INTERNAL_URL}/v1/{path}"
    body = await request.body()
    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.request(
            request.method, url, content=body,
            headers={k: v for k, v in request.headers.items() if k.lower() != "host"},
        )
    return Response(content=resp.content, status_code=resp.status_code,
                     media_type=resp.headers.get("content-type"))
