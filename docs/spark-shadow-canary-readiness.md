# Spark shadow-canary readiness — first bounded SparkCRM boundary

Readiness decision only. **No SparkCRM code changes in this card.** Defines the first
observe-only shadow-canary slice that can be reviewed and turned on safely in dev/staging.

## Evidence so far (batch vs lifecycle)

- **P3 (batch):** sanitized Spark dev `lead_signals` (3,858,208 rows) ingest through the connector;
  TBackend aggregate/query parity **exactly matches** the Spark AR baseline (count by vendor + state);
  safe compaction + reboot work. `outbox_events` was **0 rows** in the dev DB. → proves *export → side ledger*.
- **P4 (lifecycle):** a real ActiveRecord model + the `acts_as_tbackend` **after_commit macro** + live daemon:
  create/update history, latest, aggregate parity, idempotent replay, **daemon-down soft/non-fatal**. →
  proves *AR lifecycle → mirror*, but only for models written through ordinary AR callbacks.

## Load-bearing finding — LeadSignal is bulk-inserted

`Analytics::BulkLeadSignalIngestor` writes via **`LeadSignal.insert_all(...)`** (bulk). `insert_all`
**bypasses ActiveRecord callbacks**, so the P4 `after_commit` macro would **silently miss every real
lead signal**. A LeadSignal canary must therefore use an **explicit mirror call on the ingestor's
`inserted_rows`**, not the macro. The extension already supports this (`ActsAsTbackend::Mirror.mirror!`
/ `record.tbackend_fact` from app code) — same soft-fail path, different trigger.

## Candidate comparison

| candidate | real dev data | trigger | verdict |
|---|---|---|---|
| **A. LeadSignal** | ✅ 3.86M rows, parity proven | **bulk `insert_all`** → needs explicit hook on `inserted_rows`; high volume → must be **bounded/sampled** | **RECOMMENDED** — only candidate provable on real data in dev today |
| B. OutboxEvent | ❌ 0 rows in dev DB | per-row `create!` (macro-compatible), event-shaped, has `outbox_health` precedent | **rejected for first** — unprovable in this dev DB; revisit when a producer populates it (staging) |
| C. Availability / scheduling | n/a | larger domain | **rejected** — the home-lab `spark-availability-ledger-lab` is already the availability shadow reference; SparkCRM availability canary widens scope |
| D. readiness-only (no code) | — | — | **this card is D**; the deliverable is this packet + the named next implementation card |

## Recommended first canary boundary — LeadSignal, bounded explicit mirror

| dimension | decision |
|---|---|
| **model / event** | `LeadSignal` on ingest — the `inserted_rows` returned by `BulkLeadSignalIngestor` after `insert_all` commits |
| **trigger** | **explicit** `ActsAsTbackend::Mirror.mirror!(record:, store:, event_type: "ingest")` per inserted row — NOT the after_commit macro (insert_all bypasses callbacks) |
| **bounding** | a **sample gate** so the canary is a slice, not the 3.86M firehose: e.g. `lead_signal.id % SAMPLE_MOD == 0` (config `TBACKEND_CANARY_SAMPLE_MOD`, default very sparse) and/or a single channel/vendor; strictly forward-only (new ingests) |
| **store** | `spark_lead_signals` (underscore — dotted store names break `write_fact_once`, per P3) |
| **key** | `spark_lead_signals:<lead_signal_id>` |
| **id** | `spark_lead_signals:<lead_signal_id>:ingest:<updated_at_us>` (deterministic, retry-safe; updates/cancellations land as new versions) |
| **version stamp** | P6 must supply `updated_at_us` explicitly. Current `insert_all returning:` does **not** include `updated_at`; either add `updated_at` to `returning` or build a small DTO from the inserted payload/result using the same `now` value. Do not fall back to wall-clock inside the mirror. |
| **valid_time** | `signal_at` |
| **transaction_time** | server-stamped (ingest time) |
| **allowlist (mirrored)** | channel, trade_name, vendor_name, zip_code, city, county, state, timezone, accepted, bid, converted, order_status, eligibility_mode/slots/threshold, external_operator/trade/vendor_id, linkage_source/confidence, has_did, has_upi, has_request_id, has_trace_id, data_keys |
| **NEVER mirrored** | raw `did`, `upi`, `request_id`, `trace_id`, full `data` jsonb, phone/email/name/address, raw payload bodies |
| **failure behavior** | post-commit + **soft-fail**: the explicit call is rescued; the connector returns a soft status (`unavailable`/`circuit_open`/`timeout_unknown`); a mirror failure never touches the ingestor's return or the Spark write. TBackend down = silent no-op. |
| **config / flag (disabled by default)** | `ActsAsTbackend.enabled?` (ENV `TBACKEND_ENABLED`, default OFF) **AND** a canary flag (`TBACKEND_CANARY_LEADSIGNAL` or a `System::AppSetting` flag) **AND** the sample-mod. All three off/sparse by default. |
| **observability / readback** | a small health reporter (mirroring the `get_outbox_health` diagnostic style): mirror attempt / committed / replay / soft-fail counts (no payloads), plus a **parity readback** — TBackend `analytics_aggregate` over the mirrored slice vs `LeadSignal` AR for the same window. Failures logged with `store/key/status`, never the value. |
| **rollback** | one switch: `TBACKEND_ENABLED=0` (or the canary flag off) → the mirror no-ops immediately. |

## Authority boundary (explicit)

- **SparkCRM/Postgres stays the source of truth.** TBackend is **side-evidence only** — it is written
  after the AR commit, read only for parity/health, and **never** feeds a Spark decision or user flow.
- **Not production authority.** This canary is dev/staging, observe-only, bounded, disabled by default.
- **PII/payload exclusion is structural** — only the allowlist above is mirrored; raw identifiers and the
  full `data` jsonb never leave Spark.

## What would convince us to turn it on (dev/staging)

1. **Parity**: TBackend aggregate over the sampled slice matches the `LeadSignal` AR baseline for the same
   window (as P3 proved on batch).
2. **Zero app impact**: no measurable ingest-latency or error-rate change with the canary on; the explicit
   hook adds only a bounded, sampled, soft call.
3. **Daemon-down proven**: killing the local/staging daemon leaves ingest fully green (soft no-op), as P4
   proved for the lifecycle path.

## Before ANY production shadow canary (out of scope here)

Staging soak on sustained real traffic; the connector **token/auth wired to a real daemon** (not the
open loopback); a durable/recoverable daemon + backup-restore runbook; and the network/loopback security
gate. None of these are required for the dev/staging readiness canary.

## Decision + next card

**Recommendation: A — a bounded, explicit, sampled `LeadSignal` shadow mirror in the ingestor**, dev-first,
disabled by default. Rejected: OutboxEvent (empty in dev), Availability (already covered in the lab), and
"no code" (this card is that step).

**Next implementation card: `LAB-TBACKEND-SPARK-LEADSIGNAL-SHADOW-CANARY-P6`** — the smallest slice that
mirrors the sampled `inserted_rows` via the explicit soft hook behind the triple guard, with the health/
parity readback and the one-flag rollback. (SparkCRM code changes begin there, not here.)

No hard blockers. The two design corrections carried into P6: **explicit ingestor hook, not the after_commit
macro**, because `LeadSignal` is bulk-inserted; and **explicit version stamp**, because the current
`insert_all returning:` row does not include `updated_at`.
