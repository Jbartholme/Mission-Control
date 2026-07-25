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
  `asset_type`, `display_name`, `domain`, `group_name`, `schedule_cron`,
  `timezone`, `expected_duration_ms`, `owner`, `is_enabled`, `created_at`,
  `updated_at`. This is what distinguishes *failed* from *never reported*,
  and is the fallback source for `nextRunAt`. **This table is mutable at
  runtime** — see "Adding, editing, and tagging sources" below.
- `mc.asset_tag` — `(asset_id, tag)`, one row per tag. A join table, not a
  JSON/array column on `asset_registry`, because most SQL Server / Fabric
  Warehouse targets don't have a native array type, and `WHERE tag IN (...)`
  needs to stay a plain indexed join, not a JSON-parsing query.
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

## Grouping and tags at scale (~30+ monitored assets)

At 5 hand-picked assets, `domain` was enough. Past that — 30 tables spanning
Azure Table Storage, Fabric Tables, ADF pipelines, Fabric notebooks, and
Skyvern jobs — a single enum stops working, since "what business area is
this for" and "what technical bucket does this belong to" are different
questions with different cardinality.

Four established monitoring/catalog tools were checked for how they solve
exactly this (many heterogeneous items, need to browse *and* filter):
Grafana (folders + tags), Datadog (unified tagging + template variables),
Azure-native (resource tags + ADF annotations + Fabric Monitoring hub
filters), and catalog tools (Backstage's Domain/System/Component,
PagerDuty's business/technical service hierarchy). All four converge on the
**same two-part model**, so it's adopted as-is rather than invented fresh:

- **`group` — one per asset, structural.** A single parent bucket used for
  navigation and default organization (Grafana folder / Backstage System /
  Azure Workbook "group" parameter). An asset has exactly one. This is what
  puts "Azure Tables" and "Fabric Tables" in their own bucket in the UI.
- **`tags[]` — many per asset, freeform, cross-cutting.** Flat strings,
  optionally `key:value` (Datadog's convention — `env:prod`,
  `cadence:hourly`) or bare (`critical-path`, `pii`). Filtering by multiple
  tags is AND logic, matching every tool surveyed. This is what lets an
  asset surface under "prod" and "critical-path" and "hourly" simultaneously
  without needing three different group hierarchies.

`domain` (business area) stays as a separate field — it answers "who owns
this" for KPI/alert routing, which `group` (technical bucket) doesn't
capture and shouldn't. Keep hierarchy singular and push everything else
into tags; every tool surveyed breaks in the same way — usability collapses
— when items get more than one structural parent.

## Adding, editing, and tagging sources

`mc.asset_registry` is the only thing that has to change to monitor a new
table or pipeline — nothing about the collector, the API, or the frontend
should require a code change or a redeploy for the common case.

**Two different cases, two different costs:**

- **A new asset of a system already supported** (another Azure Table, another
  ADF pipeline, another Fabric table) — this is a **data-only change**: one
  new row in `asset_registry` (+ rows in `asset_tag`). The existing collector
  for that `system` picks it up on its next poll cycle automatically, because
  every collector's query is `SELECT * FROM asset_registry WHERE system = ?
  AND is_enabled = 1` — it never hardcodes a list of assets. Zero code,
  zero redeploy.
- **A genuinely new system type** (something that isn't ADF/Fabric/Skyvern/
  Azure Table/Power BI/warehouse) — this needs one new collector module
  following the existing interface (`fetch(asset) -> Observation`). That's a
  real code change, but a small, additive, one-file one — never a
  reason to touch the schema, the API, or the other collectors.

**Admin API** (same backend service, same auth boundary as the read API —
not exposed to the public internet any more than `/snapshot` is):

```
POST   /api/mission-control/assets              create
PATCH  /api/mission-control/assets/:id           update (name, group, domain,
                                                   schedule, owner, is_enabled)
POST   /api/mission-control/assets/:id/tags      add a tag
DELETE /api/mission-control/assets/:id/tags/:tag remove a tag
GET    /api/mission-control/assets/groups        distinct group names, for
                                                   the UI's "existing group"
                                                   picker
GET    /api/mission-control/assets/tags          distinct tags + counts, for
                                                   the UI's tag suggestions
```

No `DELETE /assets/:id`. Disabling (`is_enabled = false`) is the only
removal path — it stops the collector from polling and drops the asset from
the snapshot, but keeps its `asset_observation` history intact. A hard
delete would orphan history and make "why did this alert stop firing"
unanswerable later.

**Tagging happens at setup, changes in the UI.** The Add-source form (below)
requires `group` and lets you attach `tags` before the asset is saved —
nothing gets monitored untagged. After that, tags/group/schedule are
editable any time from the same UI, calling the `PATCH`/tag endpoints above;
there's no separate "re-onboarding" flow.

**Frontend — Add and Edit:**

- A **`+` button** next to the Pipelines search bar opens an Add-source
  form: name, system (dropdown), asset type, domain, **group** (dropdown of
  existing groups, or type a new one — this is the only required
  single-parent field), **tags** (chip input: type + Enter, autocompletes
  against existing tags but accepts new ones), schedule (optional — can be
  filled in later once the real trigger/refresh schedule is known), owner.
  On save: `POST /assets`, then its tags via `POST /assets/:id/tags`.
- Every asset card gets an **Edit** affordance (in its expanded detail view)
  that opens the same form pre-filled, diffed against the current values,
  and calls `PATCH` + the tag endpoints on save.
- A card's tags stay visible and removable inline (× on each chip) without
  opening the full edit form, for the common "just drop this one tag" case.

The demo console in `sample-data/` / the published artifact implements this
against its in-memory sample data (no real backend exists yet) — same form,
same fields, so the UI itself doesn't change when it's wired to the real
Admin API later, only what the Save button calls.

## Datasets: record counts, deltas, and the "0 is an issue" rule

Azure Tables, Fabric Tables, and Cubes moved out of the Pipelines tab into
their own **Datasets** section (after Overview) — they're a different kind
of thing to monitor. A pipeline either ran or didn't; a dataset also has a
*size*, and a refresh that "succeeds" but leaves the table empty is a real
failure mode that `status: "succeeded"` alone will never catch.

**Record count.** `DatasetCard.recordCount` is `SELECT COUNT(*)` (or the
source's native row-count API — Azure Table Storage and Fabric both expose
one) run at the same cadence as the rest of that asset's polling. **A
`recordCount` of `0` always raises a `critical` alert** (`ruleType:
"empty_dataset"`), independent of `status`. This is deliberately not
tied to the job/refresh status: the demonstration case in the sample data
(`Cube.DataPlatformOps`) has `status: "succeeded"` and `recordCount: 0` at
the same time — the refresh job didn't error, it just processed against an
empty or truncated source. That's the exact case a job-status-only alert
would miss.

**Delta between refreshes — yes, this is straightforward.** It doesn't
need a new table: `mc.asset_observation` (§1) is already an append-only
row per poll. If the collector writes `recordCount` into that row alongside
`status`, the delta is just comparing the latest observation to the one
before it for the same `asset_id` — a `LAG(record_count) OVER (PARTITION BY
asset_id ORDER BY observed_at)` window function, or two queries diffed in
the API layer. `recordCountPrevious` and `recordCountDelta` in the schema
below are that comparison, precomputed into the snapshot so the frontend
doesn't do arithmetic. No direction is assumed to be "good" — unlike the
KPI cards' `trendIsGood`, a shrinking table isn't necessarily bad (some
tables are meant to shrink) — the delta is shown neutrally; `recordCount:
0` is the one case treated as unconditionally wrong.

**Cube platform tags.** Cubes come from two different platforms (Azure
Analysis Services vs. a Fabric semantic model) that don't share a
`system` value cleanly the way tables do. Rather than force a single enum
split, every asset in the `Cubes` group carries a **`cube:azure` or
`cube:fabric` tag** — same tag-chip filtering as everything else, no new
UI concept, and it composes with `env:prod`, `critical-path`, etc. instead
of replacing them.

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
  sections: Record<"pipelines" | "datasets" | "pbiDatasets" | "capitalMarkets" | "callCenter", SectionMeta>;
  pipelines: PipelineCard[];          // process-monitoring: ADF/Fabric/Skyvern runs
  datasets: DatasetCard[];            // storage-monitoring: Azure Tables, Fabric Tables, Cubes
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
  group: string;                      // single parent bucket, e.g. "ADF Pipelines", "Fabric Notebooks" — structural, one per asset
  tags: string[];                     // flat, freeform, multi-membership — "env:prod", "critical-path", "pii", "cadence:hourly"
  status: UnifiedStatus; sourceStatus: string | null; statusReason: string | null;
  lastRunAt: string | null; lastRunEndedAt: string | null; lastSuccessAt: string | null;
  durationMs: number | null; avgDurationMs: number | null; expectedDurationMs: number | null;
  nextRunAt: string | null; nextRunSource: NextRunSource;
  scheduleCron: string | null; timezone: string;
  runId: string | null; runUrl: string | null;
  consecutiveFailures: number; isEnabled: boolean; isStale: boolean; asOf: string | null;
}

// Same run/refresh fields as PipelineCard, plus the count that's the whole point of a
// "dataset": a status of "succeeded" only means the refresh job didn't error — it says
// nothing about whether the data is actually there. recordCount is the second, independent
// signal, and it catches a real failure mode status alone can't: a refresh that completes
// cleanly against an empty source.
interface DatasetCard {
  id: string; name: string;
  system: "adf" | "fabric" | "skyvern" | "azure_table" | "azure_cube";
  assetType: "table" | "cube";
  domain: Domain;
  group: string;                      // "Azure Tables" | "Fabric Tables" | "Cubes" today; open to more
  tags: string[];                     // include "cube:azure" / "cube:fabric" on every Cubes-group asset
  status: UnifiedStatus; sourceStatus: string | null; statusReason: string | null;
  lastRunAt: string | null; lastRunEndedAt: string | null; lastSuccessAt: string | null;
  durationMs: number | null; avgDurationMs: number | null; expectedDurationMs: number | null;
  nextRunAt: string | null; nextRunSource: NextRunSource;
  scheduleCron: string | null; timezone: string;
  runId: string | null; runUrl: string | null;
  consecutiveFailures: number; isEnabled: boolean; isStale: boolean; asOf: string | null;
  recordCount: number | null;         // as of this poll — SELECT COUNT(*) or the source's row-count API
  recordCountPrevious: number | null; // same asset's count as of the prior poll
  recordCountDelta: number | null;    // recordCount - recordCountPrevious; null until there are two polls to diff
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
  source: "pipelines" | "datasets" | "powerbi" | "capitalMarkets" | "callCenter" | "system";
  entityId: string | null; entityName: string | null;
  entityType: "pipeline" | "notebook" | "job" | "table" | "cube" | "dataset" | "kpi" | "connection" | null;
  ruleId: string | null;
  ruleType: "status_failed" | "threshold_breach" | "stale_data" | "connection_lost"
          | "duration_exceeded" | "no_recent_run" | "empty_dataset";
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
