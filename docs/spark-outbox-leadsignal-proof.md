# Spark-shaped proof — lead_signals → TBackend analytics + compaction

Local, read-only evidence (single macOS dev box). Spark dev DBs read read-only; TBackend
runs on a loopback temp daemon. No SparkCRM writes, no production, no PII in this doc.

Reproduce:

```bash
cd runtime/acts-as-tbackend
ruby -Ilib scripts/spark_outbox_leadsignal_probe.rb --sample 5000 --scale 50000
```

The probe shells `scripts/spark_export_sample.rb` via Rails runner (from sparkcrm) to
produce a sanitized allowlisted sample, then ingests it through the **acts-as-tbackend
connector** (`write_fact_once`), measures storage, runs TBackend analytics, compares two
metrics with the Spark AR baseline, and runs safe manual compaction + a reboot check.

## Data

| | |
|---|---|
| lead_signals DB | `spark_dev_analytics_db_15_05_2026_v2` — **3,858,208 rows**, signal_at 2026-04-19 … 2026-06-25 |
| outbox_events DB | `spark_dev_db_2026_06_25` — **0 rows** (empty in this dev DB) → real proof runs on lead_signals only |
| sample | latest N by `signal_at` (N = 1000 / 5000) |

**Redaction (allowlist).** Only allowlisted fields are exported. Sensitive fields are reduced
to booleans/keys: `did`/`upi`/`request_id`/`trace_id` → `has_*`; full `data` jsonb → `data_keys`.
No raw DID/UPI/phone/email/name/address or payload bodies leave Spark.

## Ingest + storage growth (connector `write_fact_once`, accepted durability)

| sample | facts | status | ingest rpm | store size | WAL bytes | ~bytes/fact |
|---|---|---|---|---|---|---|
| 1k real | 1,000 | 1000 `committed_acked` | ~2.0M | 611,541 | 694,239 | ~611 |
| 5k real | 5,000 | 5000 `committed_acked` | ~2.0M | 3,058,584 | 3,473,844 | ~612 |
| 55k (5k real + 50k synthetic) | 55,000 | 50000 `committed_acked` | ~2.0M | 33,172,204 | 37,733,884 | **603** |

Synthetic scale = the sampled value distribution replayed under **new deterministic ids** (not
duplicated ids). Storage is linear at **~603 bytes per real-shaped lead-signal fact**.

## Analytics (all exercised on connector-written facts; 3+ ops)

- `analytics_aggregate` — count + sum(bid) by `value.vendor_name`; count by `value.state`,
  `value.channel`, `value.eligibility_mode`. Useful and correct.
- `query_slice` — `filters: { accepted: true }` → 801 of 5,000 accepted. Useful for indicator filters.
- `analytics_calculate` — SMA over `value.bid` for a key: ran OK, but it is **timeline-per-key
  oriented** (a single key's version series), not a cross-key hourly rollup. For Spark's
  `LeadSignalsHourlyLoad`-style rollups the right tool is the snapshot rollup (group-by + aggregates),
  not `analytics_calculate`.

### Baseline parity (2 metrics, same 5,000-row sample)

TBackend `analytics_aggregate` vs Spark AR/Ruby GROUP BY on the identical sample:

| metric | result |
|---|---|
| count by `vendor_name` | **exact match** |
| count by `state` | **exact match** (e.g. FL baseline 672 == TBackend 672) |

## Compaction / rollup (safe manual, `--enable-compaction true`)

Cold/warm split (real value shapes, explicit `transaction_time`: 5 cold = 4 days old > 3-day
retention, 5 warm = now), rollup policy grouped by `vendor_name`/`state`/`accepted`, aggregates
`sum(bid)` + `count`:

| | before | after |
|---|---|---|
| source store facts | 10 | **5** (5 cold pruned) |
| summary store facts | 0 | **2** (daily rollups) |
| source WAL bytes | 6,778 | **3,390** (shrank on disk) |

`snapshot_policy_create` → `pol_...`, `snapshot_trigger` → `pruned_facts: 5, created_summaries: 2`.
**Reboot after compaction:** warm facts (5) + summaries (2) preload correctly; the 55k main store
reloads intact.

## Findings — what should improve next

1. **Store names must not contain `.`** — `write_fact_once` errors on a dotted store name (the `.`
   is the analytics value-path separator / WAL filename token). The card's suggested `spark.lead_signals`
   fails; use `spark_lead_signals`. *(Worth a daemon-side validation/error-message, or documented constraint.)*
2. **`write_fact_once` needs a complete envelope** (`transaction_time` + `schema_version`) — a partial
   fact errors. The connector's `Fact.build` supplies these; hand-rolled facts must too.
3. **No two-core split:** connector-written (`write_fact_once`) facts ARE fully visible to
   `size`/`facts_by_seq`/`analytics_*`/`query_slice`/snapshot — verified directly. (Earlier confusion was
   malformed test facts, not a core divergence.)
4. **`analytics_calculate` is timeline-per-key**, not cross-key windowed — a gap for hourly-rollup
   indicators; the snapshot rollup covers cross-key group aggregates instead.
5. **outbox_events empty** in this dev DB — the outbox store shape is documented from the model but not
   exercised on real rows.

## Decision

**READY (conditional) for a Spark-shaped side-ledger experiment.** Real lead_signals ingest through the
connector, storage envelope (~603 B/fact), analytics that match Spark SQL exactly on two metrics, and safe
manual compaction + reboot all work. Conditions: use underscore store names; treat `analytics_calculate`
as per-key (use snapshot rollups for cross-key indicators). Next: a synthetic Rails-mirror path
(`LAB-TBACKEND-SPARK-SYNTHETIC-RAILS-MIRROR-P4`) and, if hourly indicators are needed, an analytics
group/window API card.
