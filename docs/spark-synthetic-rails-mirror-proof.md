# Synthetic Rails mirror proof — acts-as-tbackend extension → live TBackend

Local, synthetic-only evidence. A real ActiveRecord model (SQLite `:memory:`) using the
`acts_as_tbackend` macro, mirrored to a loopback `tbackend` daemon — the first exercise of
the P1 callback path against live AR + a live daemon. No SparkCRM, no PII, no production.

Reproduce:

```bash
cd runtime/acts-as-tbackend
ruby -Ilib scripts/synthetic_rails_mirror_proof.rb --records 60
```

## Surface under test (verify-first confirmations)

- Callback/mirror surface: `lib/acts_as_tbackend/extension.rb` (`acts_as_tbackend` macro →
  `after_commit` create/update/destroy) → `lib/acts_as_tbackend/mirror.rb`
  (`Mirror.mirror!` → `Fact.derive_id` + `client.write_fact_once_safe`).
- Stable fact id: `store:record_id:event_type:updated_at_us` — derived from `record.updated_at`.
- Daemon-down is soft (mirror runs in `after_commit`, post-commit, and returns a soft result).
- Store name is underscore (`spark_lead_signals`), per the P3 finding.

Model: `SyntheticLeadSignal(channel, vendor_name, state, accepted, bid, converted,
order_status, eligibility_mode, signal_at, timestamps)`, mirrored via
`acts_as_tbackend store: "spark_lead_signals", only: [the 8 safe columns]`. No PII columns
exist, so the mirrored value is sanitized by construction.

## Result — all 8 checks pass (60 synthetic records)

| check | result |
|---|---|
| create mirrors one fact per AR record | size = 60 |
| create mirror status | committed / idempotent_replay |
| **aggregate parity** (count by `vendor_name`) | TBackend == AR baseline (20 / 20 / 20) |
| **update → history** | `facts_for(spark_lead_signals:1)` = **2 versions** (create + update) |
| **latest matches newest AR value** | TBackend `latest_for` bid 999.99 == AR bid 999.99 |
| **idempotent re-mirror** | re-mirror → `idempotent_replay`, fact count 2 → 2 (no duplicate) |
| **daemon-down: AR write survives** | record persisted = true |
| **daemon-down: mirror soft/classified** | status = `unavailable` (no exception into the AR path) |

## What this proves

- The Rails **lifecycle** path works: `after_commit` on create/update emits a mirrored fact
  through `write_fact_once`, with no app-write fragility.
- **Bitemporal history**: an update lands as a second version under the same key; TBackend
  serves both versions (`facts_for`) and the newest (`latest_for`).
- **Retry-safe identity**: re-running the same mirror (same record + event + `updated_at`)
  is an `idempotent_replay` — never a duplicate.
- **AR stays authoritative under failure**: with the daemon down, the ActiveRecord commit
  still succeeds and the mirror returns a soft, classified status — the write path never raises.
- **Query parity**: TBackend group aggregates match the ActiveRecord baseline on the fixture.

## Findings / notes

1. **Key scheme.** The Mirror builds `key = "#{store}:#{record_id}"` (e.g. `spark_lead_signals:1`),
   not the card's suggested `lead_signal:<id>`. It works and is stable; if a store-free key is
   wanted, the Mirror `key` builder should be made configurable (small follow-up, not a blocker).
2. **Fact id includes `event_type`** (`store:rec:event:updated_at_us`), so create and update are
   distinct facts (correct for history), while a *repeat* of the same event on the same
   `updated_at` collapses to a replay (correct for idempotency).
3. **Daemon-down is doubly safe**: the mirror runs in `after_commit` (post-commit) and returns a
   soft result — a raise there could not roll back the AR write anyway.

## Decision

**READY** — the extension's synthetic Rails mirror path is correct end to end (lifecycle,
history, idempotency, daemon-down non-fatality, aggregate/latest parity). This is the bridge to
a real Spark shadow canary.

Minimal next step toward a real canary: `LAB-TBACKEND-SPARK-SHADOW-CANARY-READINESS-P5` — design
the first bounded, single-model, observe-only shadow boundary in SparkCRM (guarded by
`ActsAsTbackend.enabled?`, soft-fail, no app-write coupling), plus the small key-configurability
tweak if a store-free key is desired.
