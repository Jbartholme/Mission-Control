# Implementation Roadmap

A sequenced build plan for turning Mission Control from a mockup into a
live dashboard. Read [`data-architecture.md`](data-architecture.md) first —
this doc sequences it, it doesn't re-explain it.

Each phase lists what it produces, what it depends on, and how to know
it's actually done (not "looks done"). Phases are ordered by dependency,
not by importance — Phase 0 is boring but everything else blocks on it.

## Phase 0 — Inputs someone has to provide (no code)

Nothing in Phase 1 can start until these exist. This is the single biggest
source of stalled "AI build this dashboard" attempts — the model can't
invent your tenant ID.

- [ ] **The real source list.** Every ADF pipeline, Fabric notebook/table,
      Skyvern job, Power BI dataset, and Azure Table you actually want
      monitored — name, system, domain, **group**, starting **tags**, and
      schedule if known. This becomes the initial `mc.asset_registry` seed.
      (See "for Cursor" doc — it's built to interview you for exactly this
      list.)
- [ ] **Warehouse access**: connection details for wherever
      `Cube.CapitalMarkets` and `dbo.CallVolume` live, plus permission to
      create a new `mc` schema alongside them.
- [ ] **Azure AD app registration** (service principal) with the three
      scopes listed in `data-architecture.md` §2, and admin consent granted.
      Without this, Phase 2's ADF/Fabric/Power BI collectors have nothing
      to authenticate with.
- [ ] **Power BI tenant setting**: "Allow service principals to use Power BI
      APIs" enabled, and the SP added as Viewer on each relevant workspace.
- [ ] **Skyvern API key**, scoped to read job status.
- [ ] **Hosting decision**: Azure App Service, Container App, or Function —
      for the collector + API backend service. Any works; pick one so
      Phase 2 has a target.
- [ ] `MissionControl.jsx` — confirm whether it's being resurrected, or
      whether the console artifact built in this repo (`sample-data/` +
      the published HTML) is the frontend going forward. Phase 5 assumes
      the latter unless told otherwise.

**Done when:** every checkbox above is a real value in hand, not a TODO.

## Phase 1 — Data layer

**Depends on:** Phase 0 (warehouse access).

- Create the `mc` schema: `asset_registry`, `asset_tag`,
  `asset_observation`, `v_asset_current`, `alert_rule` (DDL sketch in
  `data-architecture.md` §1 and "Adding, editing, and tagging sources").
- Seed `asset_registry` + `asset_tag` from the Phase 0 source list.
- Seed `alert_rule` with the fixed starting thresholds (avg handle time,
  locked volume floor, etc. — whatever's known today; table-driven means
  these are a follow-up `UPDATE`, not a redeploy).

**Done when:** `SELECT * FROM mc.v_asset_current` returns one row per
seeded asset with `status = 'unknown'` (nothing's polled it yet — that's
correct, not broken).

## Phase 2 — Collectors

**Depends on:** Phase 1 (registry to read from), Phase 0 (credentials).

- One module per system: `adf.ts`, `fabric.ts`, `skyvern.ts`, `powerbi.ts`,
  `warehouse.ts` (the last one doesn't collect into `asset_observation` —
  it's queried live per §1). Each: `SELECT ... WHERE system = ? AND
  is_enabled = 1` from the registry, call the real API per asset, insert
  one `asset_observation` row per result.
- Deploy as a hosted timer per cadence: ADF/Fabric 60s, Skyvern 120s,
  Power BI 300s.
- Nightly job: delete `asset_observation` rows older than 90 days.

**Done when:** `v_asset_current` shows real `status`/`lastRunAt` values
for at least one asset per system, and they update on the next poll cycle
without a deploy.

## Phase 3 — Read API

**Depends on:** Phase 2 (something to read).

- `GET /api/mission-control/snapshot` — assembles the full payload
  (schema in `data-architecture.md`) from `v_asset_current`, the two
  warehouse KPI views, and `alert_rule` evaluation.
- `ETag` / `If-None-Match` → 304 support.

**Done when:** hitting the endpoint returns a payload matching
`MissionControlSnapshot`, and it validates against
`sample-data/active-snapshot.json`'s shape field-for-field.

## Phase 4 — Admin API (source management)

**Depends on:** Phase 1 (registry exists). Can run in parallel with
Phases 2–3 — it only touches `asset_registry`/`asset_tag`, not
`asset_observation`.

- `POST /assets`, `PATCH /assets/:id`, `POST`/`DELETE
  /assets/:id/tags/:tag`, `GET /assets/groups`, `GET /assets/tags` — see
  "Adding, editing, and tagging sources" in `data-architecture.md` for the
  exact contract.
- Auth: same boundary as the read API (internal-only). This repo doesn't
  currently specify the org's SSO/network policy — resolve that before
  this phase, don't default to open.

**Done when:** a `POST /assets` followed by a Phase 2 poll cycle makes the
new asset appear in the Phase 3 snapshot with zero code changes.

## Phase 5 — Frontend wiring

**Depends on:** Phase 3 (data to show), Phase 4 (Add/Edit to wire).

- Point the console at `GET /snapshot` (30s poll, paused on
  `document.hidden`) instead of the embedded sample JSON.
- Wire the Add-source form and each card's Edit affordance to the Phase 4
  endpoints instead of mutating local state.
- Everything else (tabs, grouping, tag filters, search, alert banner) is
  already built against this exact schema — it shouldn't need to change,
  only its data source should.

**Done when:** editing a source's group or tags in the UI, waiting one
poll cycle, and refreshing shows the change — full round trip through the
real backend.

## Phase 6 — Hardening

**Depends on:** Phase 5 (there's a real system to harden).

- Alerting on the monitor itself: if a collector hasn't written an
  observation in N× its expected cadence, that's a `stale_data` alert, not
  silence.
- Error handling per collector so one failing source (expired secret,
  renamed table) doesn't blank the other four systems' sections.
- Review whether the 30s/60s/120s/300s cadences from
  `data-architecture.md` still hold once real load/throttling is observed
  — Power BI's refresh API in particular throttles harder in practice than
  the docs suggest.

**Done when:** killing one collector's credentials degrades only its
section (`sourceState: "unauthorized"`), not the whole dashboard.

---

Phases 2 and 4 can run in parallel once Phase 1 is done (different code,
same registry table, no shared write path). Everything else is a strict
chain. If this is being handed to an AI coding agent, see
[`cursor-build-prompt.md`](cursor-build-prompt.md) — it's written to ask
for Phase 0's inputs before generating anything.
