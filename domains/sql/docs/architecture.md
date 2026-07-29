# SQL Domain — Architecture

Azure SQL Server 2025. Three check types cover everything decided in
design: is a table blank, did a proc run, do cross-domain counts
reconcile. DDL in [`../schema.sql`](../schema.sql).

## The three check types

**`not_blank`** — a table/view's row count as of the latest poll. `0` is
always `critical`, independent of anything else — same rule Mission
Control uses for its Cubes group, because a table can be perfectly
reachable and still be silently wrong.

**`proc_last_run`** — did the stored procedure run on its `schedule_cron`.
`stale_proc` fires when a proc misses its expected window — this catches
the failure mode a job scheduler's own "did it error" check misses: a proc
that simply never got invoked.

**`reconciliation`** — Dialer, Website, or Salesforce pushes
`expected_count` records toward a SQL table at `pushed_at`; `window_minutes`
(30, confirmed) later, `dh.reconciliation_check` is checked against the
real count. Short by more than the source pushed → `reconciliation_mismatch`,
`critical`. This is the one check type that watches a *seam* between
domains instead of one domain's own house — it's the only thing in the
whole ecosystem that would catch "the dialer thinks it sent 1,000 leads,
SQL only has 940."

## Where reconciliation rows come from

Each source domain writes its own `expected_count` + `pushed_at` — the SQL
domain doesn't reach into Dialer/Website/Salesforce to ask. Cleanest
mechanism: those domains `INSERT` directly into `dh.reconciliation_check`
right after they push a batch (a single scoped write, not broad access to
`dh`), or write to their own outbox that a SQL-domain job polls. Either
way, SQL still does the *comparison* — the other domain only reports what
it believes it sent.

## The remediation boundary

`dh` is the only schema in this whole ecosystem with a write path back
into production — rerun a stored procedure, clear a blocking lock. That
authority stops at the schema boundary: a `reconciliation_mismatch` traced
to the Dialer produces an alert *about* the Dialer, never an action *on*
it. If a mismatch turns out to be SQL's fault (a load proc silently
failed), that's back inside `not_blank`/`proc_last_run` territory and
fair game to fix directly.

## Alerts are stored, not derived — a deliberate difference from Mission Control

Mission Control computes `alerts[]` fresh from current state on every
read; nothing is persisted. This domain stores alerts in `dh.alert` with
`is_acknowledged`/`resolved_at` instead, because it's backing a real ops
team's real day: someone needs to acknowledge a `reconciliation_mismatch`
and have that stick, not re-derive from scratch on the next poll and lose
the fact that someone's already on it. Same severity/`ruleType` shape as
Mission Control's `Alert` either way — an Overview shell aggregating both
domains doesn't need to know which one persists and which recomputes.

## Sample data

[`sample-data/snapshot.json`](../sample-data/snapshot.json) — five
registry entries (two tables, one view, one proc, one reconciliation
pair) with one of each alert type firing, so all three check types and
the remediation boundary are visible in one file.
