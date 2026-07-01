# Local load proof — acts-as-tbackend → local tbackend daemon

Local evidence only (single macOS dev box, loopback). **Not** a stable production
benchmark and not a claim that any app should enable the mirror. Reproduce with:

```bash
cd runtime/acts-as-tbackend
ruby -Ilib scripts/load_local_daemon.rb --writes 10000 --threads 8 --pool-size 8 \
  --durability accepted --max-inflight 256
```

The driver starts a loopback `tbackend` on an ephemeral port + temp data-dir, drives
`ActsAsTbackend.client.write_fact_once_safe` with deterministic `Fact.derive_id`
facts, records status mix + latency percentiles, then stops the daemon and removes
the temp dir (keep with `KEEP_TBACKEND_LOAD_ARTIFACTS=1`).

## Measured envelope (2026-07-01)

Daemon: `igniter-tbackend` release, `--data-dir <tmp>`, loopback. Client pool = threads.

| Scenario | config | rpm | writes/s | p50 | p95 | p99 | max | status mix |
|---|---|---|---|---|---|---|---|---|
| **A — accepted baseline** | 10k · 8 thr · pool 8 · inflight 256 | **2,214,496** | 36,908 | 0.20 | 0.40 | 0.52 | 2.78 | `committed_acked` 10000 |
| **B — idempotent replay** (pass 2, same ids) | 10k · 8 thr · passes 2 | 2,526,539 | 42,109 | 0.18 | 0.34 | 0.43 | 0.70 | `idempotent_replay` 10000 · 0 conflict |
| **C — backpressure** | 10k · 32 thr · pool 32 · **inflight 4** | 19,809 | 330 | 0.29 | 0.81 | 1.43 | 10063 | `committed_acked` 9952 · `timeout_unknown` 32 · `idempotent_replay` 15 · `rejected_before_commit` 1 |
| **D — durable sample** | 1k · 8 thr · `durability durable` | 51,905 | 865 | 9.06 | 10.10 | 11.99 | 19.49 | `committed_acked` 1000 |

(latencies in ms)

## Reading it

- **Target met by a wide margin.** The operational target was 5–8k rpm (≈83–133 rps).
  Accepted durability sustains **~2.2M rpm** locally at sub-millisecond p99 — ~300× the
  target. Durable (group-commit `fdatasync`) is ~45× slower per write (p50 9 ms) but
  still **~52k rpm** — ~7× the target — with no timeout storm.
- **Idempotency holds end-to-end.** Re-writing the same deterministic ids (pass 2)
  returns `idempotent_replay` for every write, zero `duplicate_fact_id_conflict`. A
  retry is a replay, never a duplicate.
- **Backpressure is soft, not fatal.** At a deliberately hostile `--max-inflight 4`
  with 32 client threads, nothing raised into the driver: the mix is dominated by
  eventual `committed_acked` with a soft tail of `timeout_unknown` (safe-retried; some
  recovered as `idempotent_replay`) and one `rejected_before_commit`. The cost shows as
  **tail latency** (the `max` ≈ 10 s = two 5 s request timeouts from `write_fact_once_safe`),
  because the daemon's global write lock serializes writes rather than shedding hard at
  in-flight = 4. Operationally: size `--max-inflight` and `request_timeout` for the real
  concurrency; extreme under-provisioning degrades via latency, not crashes.
- **No stop conditions hit** — daemon started cleanly, protocol agreed, no indefinite
  hangs, no escaped exceptions, repeated ids replayed (not conflicted), overload stayed
  soft/retryable.

## Decision

**Ready for Spark-shaped shadow-mirror experiments.** The connector + daemon pair
clears the operational envelope with wide headroom, correct idempotency, honest soft
backpressure, and a working (slower) durable mode. Remaining validation is a synthetic
Rails-mirror path (next card), not raw throughput.
