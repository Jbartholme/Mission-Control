# Mission Control

Static UI mockup for a Vortex-hosted overview dashboard that tracks pipeline
health and business KPIs in one place, with a severity-ranked alert banner
at the top. Nothing here is wired to live data yet — all values in
`MissionControl.jsx` are hardcoded mocks meant to validate the layout and
interaction model before backend work starts.

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
  monitored asset, grouped by domain), recent alerts, and a KPI snapshot.
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
| Power BI | `pbiDatasets` array | Power BI REST API — Get Refresh History (per dataset or admin-scoped) |
| Capital Markets | `capitalMarkets` array | `Cube.CapitalMarkets` warehouse view |
| Call Center | `callCenter` array | `dbo.CallVolume` warehouse view |
| Alerts | `alerts` array | Derived from the above once live — e.g. any `Failed` status, or a KPI outside its threshold |

Open questions to settle before wiring:

- Pull ADF/Fabric run status directly from the REST API, or through a
  landing table already being populated?
- Should alert severity thresholds be configurable per metric, or a fixed
  rule set to start?

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
