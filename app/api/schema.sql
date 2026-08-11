-- PF2P_PROVENANCE — SQL schema used by pf2p/provenance-api:0.1.0
-- Applied automatically on container startup. Table creation is idempotent
-- (CREATE TABLE IF NOT EXISTS). Column migrations for pre-existing databases
-- are handled in Python (see init_db() in main.py) rather than here, since
-- SQLite's ALTER TABLE ADD COLUMN does not support IF NOT EXISTS on all
-- versions.

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

-- ---- Assets (Form 1 — New Asset Registration) -----------------------------
CREATE TABLE IF NOT EXISTS assets (
    asset_id             TEXT PRIMARY KEY,
    registered_event_id  TEXT NOT NULL REFERENCES events(event_id),
    current_title        TEXT,
    creator              TEXT,
    studio               TEXT,
    capture_date         TEXT,
    capture_location     TEXT,
    generative_content   TEXT NOT NULL DEFAULT 'UNKNOWN'
                          CHECK (generative_content IN ('NONE','PRESENT','UNKNOWN')),
    provenance_class      TEXT
                          CHECK (provenance_class IN (
                            'P0','P1','P2','P3','P4','P5','P6','P7','P8','P9')),
    software_chain       TEXT,               -- JSON array, stored as text
    original_filename    TEXT,
    source_ref           TEXT,
    confidence            TEXT NOT NULL DEFAULT 'Unknown'
                          CHECK (confidence IN (
                            'Unknown','Artist Recollection','Probable','Documented','Verified')),
    notes                TEXT
);

-- ---- Processing steps (Form 2 — Processing Registration) ------------------
CREATE TABLE IF NOT EXISTS processing_steps (
    process_id           TEXT PRIMARY KEY,
    asset_id             TEXT NOT NULL REFERENCES assets(asset_id),
    event_id             TEXT NOT NULL REFERENCES events(event_id),
    sequence             INTEGER NOT NULL,
    application          TEXT NOT NULL,
    operation_type       TEXT NOT NULL,
    generative           INTEGER NOT NULL DEFAULT 0,   -- 0/1
    material_new_content INTEGER NOT NULL DEFAULT 0,   -- 0/1
    description          TEXT,
    confidence           TEXT NOT NULL DEFAULT 'Unknown'
                          CHECK (confidence IN (
                            'Unknown','Artist Recollection','Probable','Documented','Verified')),
    UNIQUE(asset_id, sequence)
);

CREATE TABLE IF NOT EXISTS masters (
    master_id            TEXT PRIMARY KEY,
    asset_id              TEXT NOT NULL REFERENCES assets(asset_id),
    version               INTEGER NOT NULL,
    approved              INTEGER NOT NULL DEFAULT 0,
    approved_event_id     TEXT REFERENCES events(event_id),
    superseded_by         TEXT REFERENCES masters(master_id),
    sha256                TEXT,
    UNIQUE(asset_id, version)
);

CREATE TABLE IF NOT EXISTS prints (
    print_id              TEXT PRIMARY KEY,
    asset_id                TEXT NOT NULL REFERENCES assets(asset_id),
    master_id                TEXT REFERENCES masters(master_id),
    size                      TEXT,
    print_event_id            TEXT NOT NULL REFERENCES events(event_id),
    sold                       INTEGER NOT NULL DEFAULT 0,
    sale_event_id               TEXT REFERENCES events(event_id)
);

CREATE TABLE IF NOT EXISTS hash_manifest (
    file_ref                TEXT NOT NULL,
    sha256                    TEXT NOT NULL,
    computed_event_id          TEXT NOT NULL REFERENCES events(event_id),
    PRIMARY KEY (file_ref, sha256)
);

-- NOTE: no DROP, DELETE, or UPDATE statement anywhere in this file. The only
-- mutation processing_steps/masters/prints ever receive is INSERT, matching
-- the "forms create events, events update projections" principle. See
-- app/api/main.py for the corresponding application code.
