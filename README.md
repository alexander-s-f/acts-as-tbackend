# Acts As TBackend

`acts-as-tbackend` is the ActiveRecord/TBackend adapter seam for mirroring model
lifecycle facts into TBackend. Its first serious role is Spark-shaped shadow
work: side-ledger audit, replay, point-in-time explanation, and parity checks
while Rails/Postgres remains authoritative.

It is not a released gem or Igniter Lang authority. Correct status:

```text
implemented lab adapter seam
  -> shadow-ready candidate
  -> production adapter only after convergence + operations gates
```

## Current Map

| Path | Purpose |
| --- | --- |
| [`lib/acts_as_tbackend.rb`](lib/acts_as_tbackend.rb) | Adapter loader, queue worker, connection pool, and thread-local client cache. |
| [`lib/acts_as_tbackend/client.rb`](lib/acts_as_tbackend/client.rb) | TCP client for the local TBackend daemon. |
| [`lib/acts_as_tbackend/extension.rb`](lib/acts_as_tbackend/extension.rb) | ActiveRecord hook sketch for writing lifecycle facts. |
| [`lib/acts_as_tbackend/shadow_comparison.rb`](lib/acts_as_tbackend/shadow_comparison.rb) | Shadow comparison helper that records CRM-vs-VM result facts. |
| [`verify_shadow.rb`](verify_shadow.rb) | Local verification runner for TBackend shadow comparison behavior. |
| [`demo.rb`](demo.rb) | Optional in-memory ActiveRecord demo. It needs local Ruby gems available. |

## Relationship To Other Lab Packages

- Uses the local TBackend daemon/substrate from [`../igniter-tbackend`](../igniter-tbackend/).
- Uses the local VM binary from [`../igniter-vm`](../igniter-vm/) for shadow comparison checks.
- Demonstrates app/model lifecycle capture and shadow comparison.
- Does not make Rails production writes depend on TBackend until a separate
  promotion gate says so.
- Does not define mainline Igniter runtime or language authority.

## Boundary

- Shadow-ready adapter seam; not a released production gem.
- No production ActiveRecord authority without convergence/runbook/rollback gates.
- No Ledger/TBackend mainline mutation authority.
- No public API, packaging, release, deployment, performance, or compatibility claims.
- No Igniter Lang canon or runtime authority.

## Local Checks

From this directory:

```bash
ruby verify_shadow.rb
ruby demo.rb # optional; requires local ActiveRecord and SQLite gems
```
