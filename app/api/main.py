"""
PF2P_PROVENANCE API — image tag: pf2p/provenance-api:0.1.0

Phase 1 + Phase 2a scope. Implements:
  GET  /v1/status                              -> health endpoint
  POST /v1/system/verify                        -> test-only verification event
  POST /v1/assets                               -> Form 1: New Asset Registration
  GET  /v1/assets/{asset_id}                    -> read back an asset
  POST /v1/assets/{asset_id}/processing         -> Form 2: Processing Registration
  GET  /v1/assets/{asset_id}/events             -> full event history for an asset
  GET  /v1/assets/{asset_id}/provenance         -> asset + processing steps combined

No DELETE or UPDATE statement against the `events` table exists anywhere in
this file. Forms create events; events update projection tables (assets,
processing_steps, masters, prints, hash_manifest). Clients never write
projection tables directly.
"""
import hashlib
import json
import os
import re
import sqlite3
import ulid
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, field_validator

DB_PATH = os.environ.get("PF2P_DB_PATH", "/data/db/pf2p_provenance.db")
SCHEMA_PATH = Path(__file__).parent / "schema.sql"

app = FastAPI(title="PF2P Provenance API", version="0.1.0")

ASSET_ID_RE = re.compile(r"^PF2P-IMG-\d{6}$")
GENERATIVE_CONTENT_VALUES = {"NONE", "PRESENT", "UNKNOWN"}
PROVENANCE_CLASS_VALUES = {f"P{i}" for i in range(10)}
CONFIDENCE_VALUES = {"Unknown", "Artist Recollection", "Probable", "Documented", "Verified"}


def get_conn() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.execute("PRAGMA foreign_keys = ON")
    conn.row_factory = sqlite3.Row
    return conn


# Columns added after the initial Phase 1 release. Applied to existing
# databases idempotently (checked against PRAGMA table_info) since SQLite's
# ALTER TABLE ADD COLUMN does not support IF NOT EXISTS on all versions.
ASSET_COLUMN_MIGRATIONS = [
    ("current_title", "TEXT"),
    ("creator", "TEXT"),
    ("studio", "TEXT"),
    ("capture_location", "TEXT"),
    ("provenance_class", "TEXT"),
    ("original_filename", "TEXT"),
    ("source_ref", "TEXT"),
    ("confidence", "TEXT DEFAULT 'Unknown'"),
]


def apply_column_migrations(conn: sqlite3.Connection) -> None:
    existing = {row[1] for row in conn.execute("PRAGMA table_info(assets)").fetchall()}
    for col_name, col_type in ASSET_COLUMN_MIGRATIONS:
        if col_name not in existing:
            conn.execute(f"ALTER TABLE assets ADD COLUMN {col_name} {col_type}")
    conn.commit()


def init_db() -> None:
    Path(DB_PATH).parent.mkdir(parents=True, exist_ok=True)
    conn = get_conn()
    with open(SCHEMA_PATH, "r") as f:
        conn.executescript(f.read())
    conn.commit()
    apply_column_migrations(conn)
    conn.close()


def last_audit_hash(conn: sqlite3.Connection) -> str:
    row = conn.execute(
        "SELECT audit_hash FROM events ORDER BY ts_utc DESC, event_id DESC LIMIT 1"
    ).fetchone()
    return row[0] if row else "GENESIS"


def insert_event(
    conn: sqlite3.Connection,
    *,
    asset_id: Optional[str],
    actor: str,
    source_client: str,
    event_type: str,
    payload: dict,
    related_event_id: Optional[str] = None,
    approval_status: str = "not_required",
) -> str:
    event_id = str(ulid.ULID())
    ts_utc = datetime.now(timezone.utc).isoformat()
    payload_json = json.dumps(payload, sort_keys=True)
    prev_hash = last_audit_hash(conn)
    canonical = f"{prev_hash}|{event_id}|{ts_utc}|{event_type}|{payload_json}"
    audit_hash = hashlib.sha256(canonical.encode("utf-8")).hexdigest()

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


def asset_exists(conn: sqlite3.Connection, asset_id: str) -> bool:
    return conn.execute(
        "SELECT 1 FROM assets WHERE asset_id = ?", (asset_id,)
    ).fetchone() is not None


@app.on_event("startup")
def on_startup():
    init_db()


@app.get("/v1/status")
def status():
    return {"status": "ok", "service": "pf2p-provenance-api", "version": "0.1.0"}


class VerifyRequest(BaseModel):
    run_id: str
    source_client: str = "verify-script"


@app.post("/v1/system/verify")
def system_verify(req: VerifyRequest):
    conn = get_conn()
    try:
        event_id = insert_event(
            conn, asset_id=None, actor="system", source_client=req.source_client,
            event_type="SYSTEM_VERIFICATION",
            payload={"run_id": req.run_id, "note": "phase1 verification run"},
            approval_status="not_required",
        )
    except sqlite3.IntegrityError as e:
        raise HTTPException(status_code=400, detail=str(e))
    finally:
        conn.close()
    return {"event_id": event_id, "event_type": "SYSTEM_VERIFICATION", "retained": True}


# ============================================================================
# Form 1 — New Asset Registration  (event_type: ASSET_REGISTERED)
# ============================================================================

class AssetRegisterRequest(BaseModel):
    asset_id: str
    current_title: Optional[str] = None
    creator: str
    studio: Optional[str] = None
    capture_date: Optional[str] = None
    capture_location: Optional[str] = None
    generative_content: str = "UNKNOWN"
    provenance_class: str
    software_chain: Optional[list[str]] = None
    original_filename: Optional[str] = None
    source_ref: Optional[str] = None
    confidence: str
    notes: Optional[str] = None
    actor: str = "claude"
    source_client: str = "unspecified"

    @field_validator("asset_id")
    @classmethod
    def validate_asset_id(cls, v: str) -> str:
        if not ASSET_ID_RE.match(v):
            raise ValueError("asset_id must match PF2P-IMG-###### exactly")
        return v

    @field_validator("generative_content")
    @classmethod
    def validate_generative_content(cls, v: str) -> str:
        if v not in GENERATIVE_CONTENT_VALUES:
            raise ValueError(f"generative_content must be one of {GENERATIVE_CONTENT_VALUES}")
        return v

    @field_validator("provenance_class")
    @classmethod
    def validate_provenance_class(cls, v: str) -> str:
        if v not in PROVENANCE_CLASS_VALUES:
            raise ValueError(f"provenance_class must be one of {sorted(PROVENANCE_CLASS_VALUES)}")
        return v

    @field_validator("confidence")
    @classmethod
    def validate_confidence(cls, v: str) -> str:
        if v not in CONFIDENCE_VALUES:
            raise ValueError(f"confidence must be one of {CONFIDENCE_VALUES}")
        return v


@app.post("/v1/assets")
def register_asset(req: AssetRegisterRequest):
    conn = get_conn()
    try:
        if asset_exists(conn, req.asset_id):
            raise HTTPException(status_code=409, detail=f"asset_id {req.asset_id} already registered")

        payload = req.model_dump(exclude={"actor", "source_client"})
        event_id = insert_event(
            conn, asset_id=req.asset_id, actor=req.actor, source_client=req.source_client,
            event_type="ASSET_REGISTERED", payload=payload, approval_status="not_required",
        )
        conn.execute(
            """
            INSERT INTO assets (
                asset_id, registered_event_id, current_title, creator, studio,
                capture_date, capture_location, generative_content, provenance_class,
                software_chain, original_filename, source_ref, confidence, notes
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                req.asset_id, event_id, req.current_title, req.creator, req.studio,
                req.capture_date, req.capture_location, req.generative_content, req.provenance_class,
                json.dumps(req.software_chain) if req.software_chain else None,
                req.original_filename, req.source_ref, req.confidence, req.notes,
            ),
        )
        conn.commit()
    except sqlite3.IntegrityError as e:
        raise HTTPException(status_code=400, detail=str(e))
    finally:
        conn.close()
    return {"asset_id": req.asset_id, "event_id": event_id, "event_type": "ASSET_REGISTERED"}


@app.get("/v1/assets/{asset_id}")
def get_asset(asset_id: str):
    conn = get_conn()
    row = conn.execute("SELECT * FROM assets WHERE asset_id = ?", (asset_id,)).fetchone()
    conn.close()
    if not row:
        raise HTTPException(status_code=404, detail="asset not found")
    result = dict(row)
    if result.get("software_chain"):
        result["software_chain"] = json.loads(result["software_chain"])
    return result


# ============================================================================
# Form 2 — Processing Registration  (event_type: PROCESSING_REGISTERED)
# ============================================================================

OPERATION_TYPES = {
    "RAW Development", "Color / Tone Adjustment", "Crop / Composition",
    "Retouching", "Noise Reduction", "Sharpening", "Masking / Selection",
    "Object Cleanup", "Background Cleanup", "Composite",
    "Generative Addition", "Generative Replacement", "Generative Expansion",
    "Restoration", "Other",
}


class ProcessingRegisterRequest(BaseModel):
    sequence: int
    application: str
    operation_type: str
    generative: bool
    material_new_content: bool
    description: Optional[str] = None
    confidence: str
    actor: str = "claude"
    source_client: str = "unspecified"

    @field_validator("operation_type")
    @classmethod
    def validate_operation_type(cls, v: str) -> str:
        if v not in OPERATION_TYPES:
            raise ValueError(f"operation_type must be one of {sorted(OPERATION_TYPES)}")
        return v

    @field_validator("confidence")
    @classmethod
    def validate_confidence(cls, v: str) -> str:
        if v not in CONFIDENCE_VALUES:
            raise ValueError(f"confidence must be one of {CONFIDENCE_VALUES}")
        return v


@app.post("/v1/assets/{asset_id}/processing")
def register_processing(asset_id: str, req: ProcessingRegisterRequest):
    conn = get_conn()
    try:
        if not asset_exists(conn, asset_id):
            raise HTTPException(status_code=404, detail=f"asset_id {asset_id} not found — register the asset first")

        payload = req.model_dump(exclude={"actor", "source_client"})
        payload["asset_id"] = asset_id
        event_id = insert_event(
            conn, asset_id=asset_id, actor=req.actor, source_client=req.source_client,
            event_type="PROCESSING_REGISTERED", payload=payload, approval_status="not_required",
        )
        process_id = f"{asset_id}-PROC-{req.sequence:03d}"
        conn.execute(
            """
            INSERT INTO processing_steps (
                process_id, asset_id, event_id, sequence, application, operation_type,
                generative, material_new_content, description, confidence
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                process_id, asset_id, event_id, req.sequence, req.application, req.operation_type,
                int(req.generative), int(req.material_new_content), req.description, req.confidence,
            ),
        )
        conn.commit()

        warning = None
        if req.generative or req.material_new_content:
            warning = (
                "This processing step may require the asset's generative_content "
                "status to be changed to PRESENT. Not changed automatically — "
                "confirm and update the asset explicitly if appropriate."
            )
    except sqlite3.IntegrityError as e:
        raise HTTPException(status_code=400, detail=str(e))
    finally:
        conn.close()

    response = {"asset_id": asset_id, "process_id": process_id, "event_id": event_id,
                "event_type": "PROCESSING_REGISTERED"}
    if warning:
        response["warning"] = warning
    return response


@app.get("/v1/assets/{asset_id}/events")
def get_asset_events(asset_id: str):
    conn = get_conn()
    if not asset_exists(conn, asset_id):
        conn.close()
        raise HTTPException(status_code=404, detail="asset not found")
    rows = conn.execute(
        "SELECT event_id, ts_utc, actor, source_client, event_type, payload_json, "
        "related_event_id, approval_status, audit_hash FROM events "
        "WHERE asset_id = ? ORDER BY ts_utc ASC",
        (asset_id,),
    ).fetchall()
    conn.close()
    return [
        {**dict(r), "payload": json.loads(r["payload_json"])}
        for r in rows
    ]


@app.get("/v1/assets/{asset_id}/provenance")
def get_asset_provenance(asset_id: str):
    conn = get_conn()
    asset_row = conn.execute("SELECT * FROM assets WHERE asset_id = ?", (asset_id,)).fetchone()
    if not asset_row:
        conn.close()
        raise HTTPException(status_code=404, detail="asset not found")
    asset = dict(asset_row)
    if asset.get("software_chain"):
        asset["software_chain"] = json.loads(asset["software_chain"])

    processing_rows = conn.execute(
        "SELECT * FROM processing_steps WHERE asset_id = ? ORDER BY sequence ASC", (asset_id,)
    ).fetchall()
    conn.close()

    return {
        "asset": asset,
        "processing": [dict(r) for r in processing_rows],
    }


@app.get("/v1/system/verify/{event_id}")
def get_verify_event(event_id: str):
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
