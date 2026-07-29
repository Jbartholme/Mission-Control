-- SQL Domain — Data Health
-- Azure SQL Server 2025. Schema "dh" (Data Health) is dedicated to this
-- domain — no tables here are read or written by Mission Control or any
-- other domain. That isolation is the point: this domain owns its own
-- registry the same way Mission Control owns mc.asset_registry, and the
-- two never share a schema.

CREATE SCHEMA dh AUTHORIZATION dbo;
GO

-- What's monitored. One row per table/view/proc under watch.
CREATE TABLE dh.asset_registry (
    asset_id             NVARCHAR(200)  NOT NULL PRIMARY KEY,
    display_name         NVARCHAR(200)  NOT NULL,
    object_type          NVARCHAR(20)   NOT NULL
        CHECK (object_type IN ('table', 'view', 'stored_procedure')),
    schema_name           NVARCHAR(128)  NOT NULL,   -- the actual SQL schema, e.g. 'dbo'
    object_name           NVARCHAR(128)  NOT NULL,   -- the actual table/view/proc name
    check_type            NVARCHAR(20)   NOT NULL
        CHECK (check_type IN ('not_blank', 'proc_last_run', 'reconciliation')),
    group_name            NVARCHAR(100)  NOT NULL,   -- e.g. 'Lead Intake', 'Loan Origination', 'Servicing'
    business_domain        NVARCHAR(30)   NOT NULL,   -- capital_markets | call_center | servicing | data_platform | other
    owner                 NVARCHAR(100)  NULL,
    schedule_cron          NVARCHAR(50)   NULL,        -- for proc_last_run checks
    expected_duration_ms   INT            NULL,
    is_enabled             BIT            NOT NULL DEFAULT 1,
    created_at              DATETIME2      NOT NULL DEFAULT SYSUTCDATETIME(),
    updated_at              DATETIME2      NOT NULL DEFAULT SYSUTCDATETIME()
);

CREATE TABLE dh.asset_tag (
    asset_id  NVARCHAR(200) NOT NULL REFERENCES dh.asset_registry(asset_id),
    tag       NVARCHAR(100) NOT NULL,   -- freeform: 'env:prod', 'pii', 'critical-path'
    CONSTRAINT pk_asset_tag PRIMARY KEY (asset_id, tag)
);

-- Append-only. One row per poll. History for free — freshness and deltas
-- are just "the latest row" and "the latest row minus the one before it."
CREATE TABLE dh.asset_observation (
    observation_id     BIGINT IDENTITY(1,1) PRIMARY KEY,
    asset_id            NVARCHAR(200)  NOT NULL REFERENCES dh.asset_registry(asset_id),
    observed_at          DATETIME2      NOT NULL DEFAULT SYSUTCDATETIME(),
    status               NVARCHAR(20)   NOT NULL,   -- ok | warning | critical | unknown
    record_count         BIGINT         NULL,        -- not_blank checks
    proc_last_run_at      DATETIME2      NULL,        -- proc_last_run checks
    duration_ms           INT            NULL,
    error_message         NVARCHAR(1000) NULL
);
CREATE INDEX ix_asset_observation_asset_time
    ON dh.asset_observation(asset_id, observed_at DESC);

-- Cross-domain reconciliation: another domain (Dialer, Website, Salesforce)
-- pushed `expected_count` records toward a SQL table at `pushed_at`; this
-- row gets filled in once the window closes with what actually landed.
CREATE TABLE dh.reconciliation_check (
    check_id         BIGINT IDENTITY(1,1) PRIMARY KEY,
    asset_id          NVARCHAR(200) NOT NULL REFERENCES dh.asset_registry(asset_id),
    source_domain      NVARCHAR(50)  NOT NULL,   -- 'dialer' | 'website' | 'salesforce'
    expected_count      INT           NOT NULL,
    pushed_at            DATETIME2     NOT NULL,
    window_minutes       INT           NOT NULL DEFAULT 30,  -- confirmed default; tune per pair later
    actual_count         INT           NULL,
    checked_at            DATETIME2     NULL,
    within_window         BIT           NULL
);

-- Nightly retention: keep 90 days of observation history, same as Mission Control.
-- (Reconciliation checks and alerts are kept longer — they're audit trail, not telemetry.)

CREATE TABLE dh.alert (
    alert_id         BIGINT IDENTITY(1,1) PRIMARY KEY,
    asset_id          NVARCHAR(200)  NOT NULL REFERENCES dh.asset_registry(asset_id),
    severity           NVARCHAR(20)   NOT NULL,   -- critical | warning | info
    rule_type           NVARCHAR(30)   NOT NULL,   -- empty_table | stale_proc | reconciliation_mismatch
    title                NVARCHAR(200)  NOT NULL,
    message              NVARCHAR(1000) NOT NULL,
    raised_at             DATETIME2      NOT NULL DEFAULT SYSUTCDATETIME(),
    resolved_at           DATETIME2      NULL,
    is_acknowledged       BIT            NOT NULL DEFAULT 0,
    acknowledged_by        NVARCHAR(100)  NULL,
    acknowledged_at         DATETIME2      NULL
);

-- Latest known state per asset — what a dashboard or the Overview shell reads.
CREATE VIEW dh.v_asset_current AS
SELECT
    a.asset_id, a.display_name, a.object_type, a.schema_name, a.object_name,
    a.check_type, a.group_name, a.business_domain, a.is_enabled,
    o.status, o.record_count, o.proc_last_run_at, o.duration_ms,
    o.observed_at AS last_observed_at
FROM dh.asset_registry a
OUTER APPLY (
    SELECT TOP 1 *
    FROM dh.asset_observation o2
    WHERE o2.asset_id = a.asset_id
    ORDER BY o2.observed_at DESC
) o;
GO
