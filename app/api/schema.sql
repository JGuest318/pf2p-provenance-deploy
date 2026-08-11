-- PF2P_PROVENANCE — SQL schema used by pf2p/provenance-api:0.1.0
-- Applied automatically on container startup if pf2p_provenance.db has no
-- tables yet (idempotent — CREATE TABLE IF NOT EXISTS throughout).

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS events (
    event_id            TEXT PRIMARY KEY,
    asset_id            TEXT,
    ts_utc              TEXT NOT NULL,
    actor               TEXT NOT NULL,
    source_client       TEXT NOT NULL,
    event_type          TEXT NOT NULL CHECK (event_type IN (
                            'ASSET_REGISTERED','PROCESSING_REGISTERED','MASTER_APPROVED',
                            'MASTER_VERSIONED','OUTPUT_REGISTERED','PRINT_REGISTERED',
                            'PUBLICATION_REGISTERED','EXHIBITION_REGISTERED','SALE_REGISTERED',
                            'TRANSFER_REGISTERED','CONFLICT_FLAGGED','HASH_CALCULATED',
                            'LEDGER_EXPORTED','SYSTEM_VERIFICATION')),
    payload_json        TEXT NOT NULL,
    related_event_id    TEXT REFERENCES events(event_id),
    approval_status     TEXT NOT NULL DEFAULT 'not_required'
                          CHECK (approval_status IN ('not_required','pending','approved','rejected')),
    approved_by         TEXT,
    approved_at_utc     TEXT,
    audit_hash          TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_events_asset ON events(asset_id);
CREATE INDEX IF NOT EXISTS idx_events_type  ON events(event_type);
CREATE INDEX IF NOT EXISTS idx_events_ts    ON events(ts_utc);

CREATE TABLE IF NOT EXISTS assets (
    asset_id             TEXT PRIMARY KEY,
    registered_event_id  TEXT NOT NULL REFERENCES events(event_id),
    capture_date         TEXT,
    generative_content   TEXT NOT NULL DEFAULT 'UNKNOWN'
                          CHECK (generative_content IN ('NONE','PRESENT','UNKNOWN')),
    software_chain       TEXT,
    notes                TEXT
);

CREATE TABLE IF NOT EXISTS masters (
    master_id            TEXT PRIMARY KEY,
    asset_id             TEXT NOT NULL REFERENCES assets(asset_id),
    version              INTEGER NOT NULL,
    approved             INTEGER NOT NULL DEFAULT 0,
    approved_event_id    TEXT REFERENCES events(event_id),
    superseded_by        TEXT REFERENCES masters(master_id),
    sha256               TEXT,
    UNIQUE(asset_id, version)
);

CREATE TABLE IF NOT EXISTS prints (
    print_id             TEXT PRIMARY KEY,
    asset_id             TEXT NOT NULL REFERENCES assets(asset_id),
    master_id            TEXT REFERENCES masters(master_id),
    size                 TEXT,
    print_event_id       TEXT NOT NULL REFERENCES events(event_id),
    sold                 INTEGER NOT NULL DEFAULT 0,
    sale_event_id        TEXT REFERENCES events(event_id)
);

CREATE TABLE IF NOT EXISTS hash_manifest (
    file_ref             TEXT NOT NULL,
    sha256               TEXT NOT NULL,
    computed_event_id    TEXT NOT NULL REFERENCES events(event_id),
    PRIMARY KEY (file_ref, sha256)
);

-- NOTE: there is no DROP, DELETE, or UPDATE statement anywhere in this file,
-- and the application code (main.py) contains no DELETE/UPDATE against the
-- `events` table under any route — see app/api/main.py.
