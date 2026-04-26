-- ANS IPU Console — Supabase deployment tracking schema
-- Run this in the Supabase SQL Editor for your project.
-- After running: copy your project URL and anon (publishable) key into secrets.json.

CREATE TABLE IF NOT EXISTS deployments (

    -- Identity
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Device
    hostname            TEXT,
    manufacturer        TEXT,
    model               TEXT,
    serial_number       TEXT,
    uuid                TEXT,

    -- CPU
    cpu                 TEXT,
    cpu_cores           INTEGER,
    cpu_logical_procs   INTEGER,
    cpu_speed_mhz       INTEGER,

    -- Memory / Storage
    ram_gb              NUMERIC(5,1),
    disk_gb             INTEGER,

    -- Firmware
    bios_version        TEXT,
    bios_date           DATE,
    mac_addresses       TEXT,

    -- Upgrade
    os_target           TEXT,
    osd_version         TEXT,
    silent              BOOLEAN,
    no_reboot           BOOLEAN,
    skip_driver_pack    BOOLEAN,
    download_only       BOOLEAN,
    dynamic_update      BOOLEAN,

    -- Outcome
    status              TEXT        NOT NULL DEFAULT 'Running',
    error_message       TEXT,
    duration_minutes    NUMERIC(6,1),

    -- Network / Geo
    public_ip           TEXT,
    isp                 TEXT,
    city                TEXT,
    region              TEXT,
    country             TEXT,
    timezone            TEXT,

    -- Timestamps
    started_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at        TIMESTAMPTZ
);

-- Index the columns you will filter/group by most often
CREATE INDEX IF NOT EXISTS idx_deployments_status      ON deployments (status);
CREATE INDEX IF NOT EXISTS idx_deployments_os_target   ON deployments (os_target);
CREATE INDEX IF NOT EXISTS idx_deployments_model       ON deployments (model);
CREATE INDEX IF NOT EXISTS idx_deployments_started_at  ON deployments (started_at DESC);
CREATE INDEX IF NOT EXISTS idx_deployments_hostname    ON deployments (hostname);

-- ─────────────────────────────────────────────────────────────────────────────
--  Row-Level Security
--  The upgrade script uses the anon (publishable) key.  RLS policies below
--  grant exactly the operations the script needs and nothing more.
--  The service-role key is never stored on managed machines.
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE deployments ENABLE ROW LEVEL SECURITY;

-- Read: any anon/authenticated caller can SELECT (e.g. a read-only dashboard)
CREATE POLICY "anon_read" ON deployments
    FOR SELECT
    TO anon, authenticated
    USING (true);

-- Insert: anon can create new deployment records
CREATE POLICY "anon_insert" ON deployments
    FOR INSERT
    TO anon
    WITH CHECK (true);

-- Update: anon can only update rows that are still Running.
-- Once status transitions to 'Complete' or 'Error' the row is immutable
-- via the anon key; only service-role can modify completed records.
CREATE POLICY "anon_update" ON deployments
    FOR UPDATE
    TO anon
    USING   (status = 'Running')
    WITH CHECK (true);

-- DELETE and DDL are service-role only (bypasses RLS, no explicit policy needed)

-- ─────────────────────────────────────────────────────────────────────────────
--  Useful views
-- ─────────────────────────────────────────────────────────────────────────────

-- Summary by status
CREATE OR REPLACE VIEW deployment_summary AS
SELECT
    status,
    COUNT(*)                                        AS count,
    ROUND(AVG(duration_minutes)::NUMERIC, 1)        AS avg_duration_min,
    ROUND(AVG(ram_gb)::NUMERIC, 1)                  AS avg_ram_gb
FROM deployments
GROUP BY status;

-- Top failure patterns
CREATE OR REPLACE VIEW top_errors AS
SELECT
    error_message,
    COUNT(*)    AS occurrences,
    MAX(started_at) AS last_seen
FROM deployments
WHERE status = 'Error'
  AND error_message IS NOT NULL
GROUP BY error_message
ORDER BY occurrences DESC;

-- Fleet OS distribution
CREATE OR REPLACE VIEW os_distribution AS
SELECT
    os_target,
    status,
    COUNT(*) AS count
FROM deployments
GROUP BY os_target, status
ORDER BY os_target, status;
