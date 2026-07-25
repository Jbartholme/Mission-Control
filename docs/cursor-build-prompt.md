# Cursor build prompt

**How to use this file:** paste everything below the line into Cursor's
Agent/Composer as your first message, in this repo, with `docs/`,
`sample-data/`, and the published console HTML available to it. It's
written as an instruction to the coding agent, not as prose about the
project — that's intentional.

---

You are setting up the real backend and wiring the real frontend for
**Mission Control**, an internal ops dashboard currently existing only as
a design doc and a static mock (`docs/data-architecture.md`,
`docs/implementation-roadmap.md`, `sample-data/*.json`, and a self-contained
HTML console under `sample-data/` or linked from the README). Read all
three docs before doing anything else — they contain the schema, the
storage/connection architecture, and the phase-by-phase build order. Do
not re-derive or redesign any of it; implement what's specified. If
something in your judgment is wrong, say so and propose a change — don't
silently deviate.

## Step 1 — Ask before you build. Do not skip this.

You cannot produce a working system from the docs alone — they describe
the *shape* of the data, not the *actual* sources, credentials, or asset
list. Before writing any code, ask the user for the following, and wait
for real answers. Do not invent placeholder values and proceed; a wrong
guess here means every phase after it is wrong too.

**1. The source list.** Ask for it as a table (a pasted spreadsheet, CSV,
or a plain list is all fine) with one row per monitored asset:

| name | system | assetType | domain | group | tags | schedule (cron, optional) |
|---|---|---|---|---|---|---|

- `system` must be one of: `adf`, `fabric`, `skyvern`, `azure_table`
  (extend this enum only if the user names a system not on this list —
  see Step 5).
- `domain` must be one of: `capital_markets`, `call_center`, `servicing`,
  `data_platform`, `other`.
- `group` is freeform but should be **small in count** relative to the
  asset list (5–15 groups for 30+ assets is the target — if the user's
  answer would produce one group per asset, push back and suggest
  consolidating by system or team, per `data-architecture.md`'s "Grouping
  and tags" section).
- `tags` — ask specifically whether they want the `env:prod` / `pii` /
  `critical-path` style used in the sample data, or their own convention.
  Either is fine; consistency across the list is what matters.

If the user doesn't have this list ready, do not proceed to Step 2 with a
made-up one — offer to seed `mc.asset_registry` with just the assets
already in `sample-data/active-snapshot.json` (clearly marked as sample
data, `is_enabled = false`) so the schema/collector/API can be built and
tested, and get the real list before Phase 5 (frontend wiring) or before
go-live, whichever the user prefers.

**2. Connection details**, one per system that's actually in use:

- Azure AD app registration: tenant ID, client ID, and confirmation the
  three API scopes in `data-architecture.md` §2 have admin consent.
  (Client secret / cert should go directly into Key Vault or the hosting
  platform's secret store — do not ask the user to paste it into chat.)
- Warehouse: connection string or the equivalent for wherever
  `Cube.CapitalMarkets` / `dbo.CallVolume` live, and confirmation of
  permission to create a new `mc` schema there.
- Skyvern: which auth header/API key convention their instance uses.
- Power BI: confirm the tenant setting for service-principal API access is
  enabled and the SP is added to the relevant workspaces.

**3. Hosting target.** Azure App Service, Container App, or Function —
ask which, don't assume.

**4. Anything in the docs they want changed.** Specifically flag the two
"open questions" `data-architecture.md` already took a position on
(landing-table ownership, fixed-vs-configurable alert thresholds) and the
polling cadences in §3 — ask if those defaults are acceptable or need
overriding before you build to them.

Only once you have real answers to 1–4 (or an explicit "use the sample
data / defaults for now" from the user) should you move to Step 2.

## Step 2 — Build in phase order

Follow `docs/implementation-roadmap.md` exactly, in order: schema (Phase
1) → collectors (Phase 2) → read API (Phase 3) → admin API (Phase 4) →
frontend wiring (Phase 5) → hardening (Phase 6). Phases 2 and 4 may run
concurrently once Phase 1 is done; nothing else should be reordered —
each phase's "done when" check is a real gate, not a suggestion.

Match the schema in `data-architecture.md` exactly — field names, types,
and nullability. The frontend (the existing console) is already built
against this schema; if you change a field name, you will break it and
have to update the console too, so don't unless the user asks.

Use `mc.asset_tag` as a join table (`asset_id, tag`), not a JSON/array
column — see the schema doc for why.

## Step 3 — After each phase, report and stop for confirmation

Don't chain all six phases into one silent run. After each phase, state
what you built, run its "done when" check from the roadmap, and show the
result (a query result, a curl response, a screenshot) before starting
the next phase. If a "done when" check fails, fix it before moving on —
don't carry a broken phase forward.

## Step 4 — Frontend

The existing console (sample data + HTML) already implements: tabs,
group-collapsible sections, tag-chip filtering (AND logic), search, and the
Add-source (header button, Pipelines tab only) and Edit forms. It renders
a single snapshot object — the sample data stands in for the real
`/snapshot` response, not a toggle-able demo state. In Phase 5, point it at
the real `/snapshot` endpoint and wire Add/Edit to the real Admin API —
don't rebuild the UI from scratch. If a UI piece is missing
for something the real backend needs (e.g., a field the user's source
list has that the sample data doesn't), extend the existing console's
form/schema rather than starting a new component.

## Step 5 — If you hit something the docs don't cover

The docs cover: 5 known systems, the group+tags model, storage, auth per
system, polling cadences, and source CRUD. If you hit a genuine gap (a
6th system type, an auth model not listed, a warehouse that isn't SQL) —
stop and ask, the same as Step 1. Guessing here is exactly the failure
mode this file exists to prevent.
