# Mission Control

Static UI mockup for a Vortex-hosted overview dashboard that tracks pipeline
health and business KPIs in one place, with a severity-ranked alert banner
at the top. Nothing here is wired to live data yet — `console/index.html`
runs entirely against the sample fixtures in `sample-data/`, meant to
validate the layout and interaction model before backend work starts. (The
originally-planned React component, `MissionControl.jsx`, was never
committed — `console/index.html` is the working build in its place.)

**This repo also hosts other domains in a larger data-health ecosystem,**
each in its own top-level folder under `domains/`, deliberately separate
from Mission Control — own schema, own docs, own sample data, no shared
code. Mission Control itself is that ecosystem's Power BI/Fabric domain;
see [`domains/sql/`](domains/sql/) for the first other one (Azure SQL
Server: blank-table checks, stored-proc schedule checks, and cross-domain
reconciliation against Dialer/Website/Salesforce).

[`overview/index.html`](overview/index.html) is the shared shell for that
ecosystem — sidebar nav, one page per domain, a severity-sorted alert
banner aggregated across all of them. Only SQL is wired to real (sample)
data today; Website/Dialer/Salesforce show as "not connected yet" until
those domains exist, and Power BI/Fabric links out to Mission Control
rather than duplicating it. Self-contained, no build step — open directly
in a browser, same as Mission Control's own console.

## Stack

- React (function components + hooks, no external state library)
- Tailwind CSS utility classes
- [lucide-react](https://lucide.dev/) for icons

## Structure

Single-file component: `MissionControl.jsx`. Sections, top to bottom:

- **`AlertBanner`** — collapsible strip pinned to the top of the page.
  Sorts a flat `alerts` array by severity (`critical` > `warning` > `info`)
  and always leads with the worst one.
- **`Overview`** — summary stat cards, a "systems pulse" strip (one dot per
  monitored asset, grouped by `group`), recent alerts, and a KPI snapshot.
- **`Datasets`** — Azure Tables, Fabric Tables, and Cubes, grouped
  accordingly. Each card shows a record count and the delta since the prior
  refresh; a record count of `0` is always flagged, independent of the
  refresh job's own status.
- **`Pipelines`** — ADF pipeline / Fabric notebook / Skyvern job status
  cards (status, last run, duration, next run).
- **`PowerBI`** — dataset refresh cards shaped after the Power BI REST API's
  refresh-history response (status, refresh type, duration).
- **`BusinessKPIs`** — Capital Markets (`Cube.CapitalMarkets`) and Call
  Center (`dbo.CallVolume`) metric tiles.

Tab state is local (`useState`) in the root `MissionControl` export; there's
no routing.

## Mock data → real data (next steps)

| Section | Mock source | Real source to wire up |
|---|---|---|
| Pipelines | `pipelines` array | ADF pipeline-run REST API, or a landing table if one already exists |
| Datasets | `datasets` array | Azure Table Storage / Fabric / cube row-count APIs, polled alongside refresh status |
| Power BI | `pbiDatasets` array | Power BI REST API — Get Refresh History (per dataset or admin-scoped) |
| Capital Markets | `capitalMarkets` array | `Cube.CapitalMarkets` warehouse view |
| Call Center | `callCenter` array | `dbo.CallVolume` warehouse view |
| Alerts | `alerts` array | Derived from the above once live — e.g. any `Failed` status, or a KPI outside its threshold |

Open questions to settle before wiring:

- Pull ADF/Fabric run status directly from the REST API, or through a
  landing table already being populated?
- Should alert severity thresholds be configurable per metric, or a fixed
  rule set to start?

See [`docs/data-architecture.md`](docs/data-architecture.md) for a proposed
answer to both, plus storage design, connection/auth patterns per system,
and a polling strategy for keeping the dashboard current. It defines a
unified snapshot schema, with two sample fixtures in `sample-data/`:

- [`active-snapshot.json`](sample-data/active-snapshot.json) — a populated,
  "connected" snapshot (mixed statuses, a failed job, a threshold breach)
  for building and demoing the live/interactive UI.
- [`inactive-snapshot.json`](sample-data/inactive-snapshot.json) — the
  "nothing connected yet" state, for the disconnected/placeholder UI before
  any collector exists.

[`console/index.html`](console/index.html) is a working build of the
console against `active-snapshot.json` — Overview, Datasets (Azure/Fabric
Tables + Cubes, record counts and deltas), Pipelines, Power BI, and
Business KPIs, with grouping, tag filtering, search, and an Add/Edit-source
flow. Self-contained, no build step: open the file directly in a browser.
This is the real frontend to extend in Phase 5 of the roadmap below, not a
throwaway mock.

For actually building the backend: [`docs/implementation-roadmap.md`](docs/implementation-roadmap.md)
is the sequenced, phase-by-phase plan (a human-readable build order with
dependencies and "done when" checks per phase). If handing the build to an
AI coding agent, [`docs/cursor-build-prompt.md`](docs/cursor-build-prompt.md)
is a ready-to-paste prompt written to make the agent ask for the real
source list, credentials, and hosting target before it generates anything.

## Running locally

This is a single component, not a full app scaffold. Drop it into an
existing React + Tailwind project (e.g. the Vortex canvas) and render
`<MissionControl />`. Tailwind must be configured to scan this file's
`className` usage, and `lucide-react` needs to be installed:

```bash
npm install lucide-react
```

## License

Internal AmeriSave tooling — not for external distribution.
