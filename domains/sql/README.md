# SQL Domain — Data Health

Monitors Azure SQL Server 2025: are key tables/views blank, are stored
procedures running on schedule, and do record counts reconcile with what
other domains (Dialer, Website, Salesforce Marketing Cloud) pushed toward
SQL. This is the hub domain in the larger ecosystem — every other domain's
output eventually gets checked against what actually landed here — and the
only domain with authority to fix anything, scoped strictly to its own
walls (rerun a proc, clear a lock; never reaches into another domain).

Its data model is separate from Mission Control's on purpose — own schema
(`dh`), no shared tables — but the *console* is unified: SQL is a page in
[`../../console/index.html`](../../console/index.html) alongside the
Power BI/Fabric pages (Datasets, Pipelines, Power BI, Business KPIs), one
sidebar, one aggregated alert banner. See
[`docs/architecture.md`](docs/architecture.md) for the design and
[`schema.sql`](schema.sql) for the Azure SQL Server DDL.
