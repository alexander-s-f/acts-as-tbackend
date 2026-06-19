# Acts As TBackend Lab Sketch

`acts-as-tbackend` is a lab-only ActiveRecord/TBackend adapter sketch. It
explores how model lifecycle facts can be mirrored into the local TBackend
playground for shadow comparison and audit experiments.

This package is frontier evidence inside `igniter-lab`; it is not a released
adapter, runtime surface, or Igniter Lang authority.

## Current Map

| Path | Purpose |
| --- | --- |
| [`lib/acts_as_tbackend.rb`](lib/acts_as_tbackend.rb) | Adapter loader, queue worker, connection pool, and thread-local client cache. |
| [`lib/acts_as_tbackend/client.rb`](lib/acts_as_tbackend/client.rb) | TCP client for the local TBackend playground server. |
| [`lib/acts_as_tbackend/extension.rb`](lib/acts_as_tbackend/extension.rb) | ActiveRecord hook sketch for writing lifecycle facts. |
| [`lib/acts_as_tbackend/shadow_comparison.rb`](lib/acts_as_tbackend/shadow_comparison.rb) | Shadow comparison helper that records CRM-vs-VM result facts. |
| [`verify_shadow.rb`](verify_shadow.rb) | Local verification runner for TBackend shadow comparison behavior. |
| [`demo.rb`](demo.rb) | Optional in-memory ActiveRecord demo. It needs local Ruby gems available. |

## Relationship To Other Lab Packages

- Uses the local TBackend playground from [`../igniter-tbackend`](../igniter-tbackend/).
- Uses the local VM binary from [`../igniter-vm`](../igniter-vm/) for shadow comparison checks.
- Demonstrates app/model lifecycle capture only.
- Does not define mainline Igniter runtime, persistence, ActiveRecord, or production adapter behavior.

## Boundary

- Lab-only adapter sketch.
- No production ActiveRecord integration authority.
- No Ledger/TBackend mainline mutation authority.
- No public API, packaging, release, deployment, performance, or compatibility claims.
- No Igniter Lang canon or runtime authority.

## Local Checks

From this directory:

```bash
ruby verify_shadow.rb
ruby demo.rb # optional; requires local ActiveRecord and SQLite gems
```
