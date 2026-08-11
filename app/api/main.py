"""
PF2P_PROVENANCE API — image tag: pf2p/provenance-api:0.1.0

Phase 1 scope only. Implements:
  GET  /v1/status                -> health endpoint used by Compose healthcheck
  POST /v1/system/verify          -> inserts an immutable SYSTEM_VERIFICATION event

No DELETE or UPDATE statement against the `events` table exists anywhere in
this file, and no route accepts a filesystem path outside /data or
/archive_readonly. This is intentional and permanent, not a Phase 1 gap.
"""
import hashlib
import json
import os
import sqlite3
import ulid  # lightweight ULID generator; see requirements.txt
from datetime import datetime, timezone
from pathlib import Path

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

DB_PATH = os.environ.get("PF2P_DB_PATH", "/data/db/pf2p_provenance.db")
SCHEMA_PATH = Path(__file__).parent / "schema.sql"

app = FastAPI(title="PF2P Provenance API", version="0.1.0")


def get_conn() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def init_db() -> None:
    Path(DB_PATH).parent.mkdir(parents=True, exist_ok=True)
    conn = get_conn()
    with open(SCHEMA_PATH, "r") as f:
        conn.executescript(f.read())
    conn.commit()
    conn.close()


def last_audit_hash(conn: sqlite3.Connection) -> str:
    row = conn.execute(
        "SELECT audit_hash FROM events ORDER BY ts_utc DESC, event_id DESC LIMIT 1"
    ).fetchone()
    return row[0] if row else "GENESIS"


def insert_event(
    conn: sqlite3.Connection,
    *,
    asset_id: str | None,
    actor: str,
    source_client: str,
    event_type: str,
    payload: dict,
    related_event_id: str | None = None,
    approval_status: str = "not_required",
) -> str:
    event_id = str(ulid.ULID())
    ts_utc = datetime.now(timezone.utc).isoformat()
    payload_json = json.dumps(payload, sort_keys=True)
    prev_hash = last_audit_hash(conn)
    canonical = f"{prev_hash}|{event_id}|{ts_utc}|{event_type}|{payload_json}"
    audit_hash = hashlib.sha256(canonical.encode("utf-8")).hexdigest()

    # INSERT-only. There is no corresponding UPDATE/DELETE path for this
    # table anywhere in the application.
    conn.execute(
        """
        INSERT INTO events (
            event_id, asset_id, ts_utc, actor, source_client, event_type,
            payload_json, related_event_id, approval_status, audit_hash
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            event_id, asset_id, ts_utc, actor, source_client, event_type,
            payload_json, related_event_id, approval_status, audit_hash,
        ),
    )
    conn.commit()
    return event_id


@app.on_event("startup")
def on_startup():
    init_db()


@app.get("/v1/status")
def status():
    # Used verbatim by the Compose healthcheck:
    #   CMD curl -sf http://localhost:8420/v1/status
    return {"status": "ok", "service": "pf2p-provenance-api", "version": "0.1.0"}


class VerifyRequest(BaseModel):
    run_id: str
    source_client: str = "verify-script"


@app.post("/v1/system/verify")
def system_verify(req: VerifyRequest):
    """
    Inserts one SYSTEM_VERIFICATION event and returns its event_id.
    This event is never deleted by any code path in this service —
    retention is permanent, matching the append-only provenance model.
    """
    conn = get_conn()
    try:
        event_id = insert_event(
            conn,
            asset_id=None,
            actor="system",
            source_client=req.source_client,
            event_type="SYSTEM_VERIFICATION",
            payload={"run_id": req.run_id, "note": "phase1 verification run"},
            approval_status="not_required",
        )
    except sqlite3.IntegrityError as e:
        raise HTTPException(status_code=400, detail=str(e))
    finally:
        conn.close()
    return {"event_id": event_id, "event_type": "SYSTEM_VERIFICATION", "retained": True}


@app.get("/v1/system/verify/{event_id}")
def get_verify_event(event_id: str):
    """Read-only lookup, used to independently confirm retention (Test 8b proof)."""
    conn = get_conn()
    row = conn.execute(
        "SELECT event_id, ts_utc, actor, source_client, event_type, payload_json, audit_hash "
        "FROM events WHERE event_id = ? AND event_type = 'SYSTEM_VERIFICATION'",
        (event_id,),
    ).fetchone()
    conn.close()
    if not row:
        raise HTTPException(status_code=404, detail="not found")
    return {
        "event_id": row[0], "ts_utc": row[1], "actor": row[2],
        "source_client": row[3], "event_type": row[4],
        "payload": json.loads(row[5]), "audit_hash": row[6],
    }
