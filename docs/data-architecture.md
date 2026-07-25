# Data Architecture — Storage, Connections, Freshness

Answers the "Mock data → real data" open questions from the README. This is
advisory/greenfield: nothing below is built yet, and exact field mappings
(warehouse column names, Skyvern's status vocabulary) need one reconciliation
pass once `MissionControl.jsx` and the warehouse DDL are available.

## 1. Storage — hybrid, split by source type

**Replicate the API sources. Query through for the SQL sources.**

ADF, Fabric, Skyvern, and Power BI get polled by a collector and written into
a small `mc` schema in the existing warehouse:

- `mc.asset_registry` — catalog of what's monitored: `asset_id`, `system`,
  `asset_type`, `display_name`, `domain`, `schedule_cron`, `timezone`,
  `expected_duration_ms`, `owner`, `is_enabled`. This is what distinguishes
  *failed* from *never reported*, and is the fallback source for `nextRunAt`.
- `mc.asset_observation` — append-only, one row per poll. No update logic,
  history for free, nightly delete past 90 days.
- `mc.v_asset_current` — view selecting the latest observation per asset.
- `mc.alert_rule` — thresholds (see §4).

`Cube.CapitalMarkets` and `dbo.CallVolume` are **not** copied — they already
live in the warehouse, so duplicating them adds a staleness layer for no
benefit. Query them directly with a 5-minute server-side cache.

Don't build on another team's pre-existing ADF/Fabric landing table if one
exists. Reading it as a bonus signal is fine, but owning the collector means
owning the schema and the SLA — inheriting a silently-changed column is a
common way ops dashboards break.

## 2. Connections — one backend service owns everything

The frontend (a static canvas, Vortex) never talks to Azure directly: it
can't hold a client secret, ADF/Power BI REST APIs don't support browser
CORS, and a token in the browser is an audit finding. One backend service
(collector + read API) holds all credentials.

| System | Auth |
|---|---|
| ADF | Azure AD app registration, client-credentials, scope `https://management.azure.com/.default`, RBAC *Data Factory Reader* |
| Fabric | Same SP, scope `https://api.fabric.microsoft.com/.default`, workspace Viewer |
| Power BI | Same SP, scope `https://analysis.windows.net/powerbi/api/.default`. Requires tenant setting "Allow service principals to use Power BI APIs" and adding the SP to each workspace as Viewer. Use **per-workspace/per-dataset** calls, not admin-scoped (`Tenant.Read.All` is a much harder approval for marginal benefit) |
| Warehouse | Managed identity if Azure SQL/Fabric; otherwise a dedicated read-only SQL login scoped to `SELECT` on the two views |
| Skyvern | API key header, polled. Prefer its webhook later, but poll as baseline — webhooks need an inbound public endpoint |

Secrets live in Key Vault, fetched via managed identity. No orchestration
platform needed for the collector itself — a hosted timer with one job per
source is sufficient.

## 3. Calling the data — pull, one endpoint, visible staleness

Frontend polls `GET /api/mission-control/snapshot` every **30s while the tab
is visible** (paused on `document.hidden`), with `ETag`/`If-None-Match` so
unchanged snapshots return 304. One request, one payload, no per-section
waterfall.

Collector cadences: ADF/Fabric **60s**, Skyvern **120s**, Power BI **300s**
(refreshes take minutes and the API throttles), warehouse KPIs **300s cache
TTL**. Alerts are computed at snapshot-assembly time, never stored.

No push, no event streaming — a few hundred rows/hour for a handful of
internal viewers with 30-second tolerance doesn't justify SignalR/Event Hubs.

Every section carries `asOf` and an `isStale` flag (set past ~3x its poll
interval). A card that can't be refreshed shows `unknown`, not a stale value
presented as current.

**`nextRunAt`, three tiers:** (1) the real schedule — ADF *Triggers – List By
Factory* recurrence, Power BI *Get Refresh Schedule*; (2) fall back to
`schedule_cron` in `asset_registry`; (3) otherwise `null` with
`nextRunSource: "unknown"`. Never extrapolate from median run interval — a
confidently-wrong time is worse than a blank. All timestamps ISO-8601 UTC;
durations always numeric `durationMs`.

## 4. The two open questions from the README — positions

**Landing table, ours.** Request-time fan-out to four authenticated APIs
makes page latency equal the slowest API, and one expired secret blanks the
whole dashboard.

**Fixed rules, table-driven from day one.** Seed `mc.alert_rule` with fixed
thresholds; no config UI. A threshold change becomes a SQL `UPDATE`, not a
redeploy — thresholds will get tweaked in month one, and hardcoding them in
JSX is a guaranteed regret.

*(The "systems pulse" strip needs no array of its own — derive it from
`pipelines[]` + `pbiDatasets[]` grouped by `domain`.)*

## Unified snapshot schema

Two sample fixtures implement this schema:
[`sample-data/active-snapshot.json`](../sample-data/active-snapshot.json)
(a populated, connected snapshot — mixed statuses, a failed job, a KPI
threshold breach, for building/demoing the live UI) and
[`sample-data/inactive-snapshot.json`](../sample-data/inactive-snapshot.json)
(the disconnected/placeholder state, see conventions below). Shape
(TypeScript):

```ts
type UnifiedStatus = "succeeded" | "failed" | "running" | "queued"
                    | "cancelled" | "skipped" | "unknown";
type Severity     = "critical" | "warning" | "info";
type KpiStatus    = "ok" | "warning" | "critical" | "unknown";
type SourceState  = "ok" | "degraded" | "unreachable" | "unauthorized" | "not_configured";
type NextRunSource = "trigger" | "registry_cron" | "unknown";
type Domain       = "capital_markets" | "call_center" | "servicing" | "data_platform" | "other";

interface MissionControlSnapshot {
  schemaVersion: string;
  generatedAt: string;                // ISO-8601 UTC
  environment: "prod" | "uat" | "dev";
  connection: { state: "connected" | "degraded" | "disconnected"; message: string | null };
  sections: Record<"pipelines" | "pbiDatasets" | "capitalMarkets" | "callCenter", SectionMeta>;
  pipelines: PipelineCard[];
  pbiDatasets: PbiDatasetCard[];
  capitalMarkets: KpiCard[];
  callCenter: KpiCard[];
  alerts: Alert[];
}

interface SectionMeta {
  sourceState: SourceState;
  asOf: string | null;
  staleAfterSeconds: number;
  isStale: boolean;
  itemCount: number;
  error: { code: string; message: string; occurredAt: string } | null;
}

interface PipelineCard {
  id: string; name: string;
  system: "adf" | "fabric" | "skyvern";
  assetType: "pipeline" | "notebook" | "job";
  domain: Domain;
  status: UnifiedStatus; sourceStatus: string | null; statusReason: string | null;
  lastRunAt: string | null; lastRunEndedAt: string | null; lastSuccessAt: string | null;
  durationMs: number | null; avgDurationMs: number | null; expectedDurationMs: number | null;
  nextRunAt: string | null; nextRunSource: NextRunSource;
  scheduleCron: string | null; timezone: string;
  runId: string | null; runUrl: string | null;
  consecutiveFailures: number; isEnabled: boolean; isStale: boolean; asOf: string | null;
}

interface PbiDatasetCard {
  id: string; name: string; workspaceId: string | null; workspaceName: string | null; domain: Domain;
  status: UnifiedStatus; sourceStatus: string | null;
  refreshType: "Scheduled" | "OnDemand" | "ViaApi" | "ViaEnhancedApi" | "Manual" | "unknown";
  startTime: string | null; endTime: string | null; durationMs: number | null; lastSuccessAt: string | null;
  nextRefreshAt: string | null;
  refreshSchedule: { enabled: boolean; days: string[]; times: string[]; timeZone: string } | null;
  refreshesUsedToday: number | null; refreshLimitPerDay: number | null;
  errorCode: string | null; errorMessage: string | null; requestId: string | null; datasetUrl: string | null;
  isConfiguredRefresh: boolean; consecutiveFailures: number; isStale: boolean; asOf: string | null;
}

interface KpiCard {
  id: string; label: string; domain: Domain;
  value: number | null;
  unit: "usd" | "count" | "percent" | "bps" | "seconds" | "ratio" | "days";
  formatHint: "currency" | "currencyCompact" | "integer" | "decimal1" | "percent1" | "duration";
  previousValue: number | null; comparisonLabel: string | null;
  changeAbsolute: number | null; changePercent: number | null;
  trend: "up" | "down" | "flat" | "unknown"; trendIsGood: boolean | null;
  threshold: { warning: number | null; critical: number | null; direction: "above" | "below"; ruleId: string | null } | null;
  status: KpiStatus;
  grain: "intraday" | "daily" | "wtd" | "mtd" | "qtd" | "ytd";
  asOfDate: string | null; periodStart: string | null; periodEnd: string | null;
  sourceView: string; sourceColumn: string | null; isStale: boolean; asOf: string | null;
}

interface Alert {
  id: string; severity: Severity; severityRank: number;
  title: string; message: string;
  source: "pipelines" | "powerbi" | "capitalMarkets" | "callCenter" | "system";
  entityId: string | null; entityName: string | null;
  entityType: "pipeline" | "notebook" | "job" | "dataset" | "kpi" | "connection" | null;
  ruleId: string | null;
  ruleType: "status_failed" | "threshold_breach" | "stale_data" | "connection_lost" | "duration_exceeded" | "no_recent_run";
  observedValue: number | string | null; thresholdValue: number | string | null;
  raisedAt: string; lastSeenAt: string;
  isAcknowledged: boolean; acknowledgedBy: string | null; acknowledgedAt: string | null;
  deepLink: string | null;
}
```

### Fixture conventions for the "inactive / disconnected" state

- `connection.state = "disconnected"`; every `sections.*.sourceState =
  "unreachable"`, `asOf = null`, `isStale = true`, `error` populated.
- Pipelines/datasets: `status = "unknown"`, all timestamps and numeric
  fields `null` (**never `0`** — zero reads as a real measured value),
  `nextRunSource = "unknown"`.
- KPIs: `value = null`, `status = "unknown"`, `trend = "unknown"`. Keep
  `label`, `unit`, `formatHint`, `threshold`, `sourceView` populated so the
  card shell still renders, with an em-dash where the number goes.
- `alerts[]` contains exactly one entry: a `critical` / `connection_lost`
  alert from `source: "system"`, so the banner has something correct to
  lead with instead of rendering empty.
