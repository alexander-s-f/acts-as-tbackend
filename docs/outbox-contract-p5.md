# Outbox Contract (P5)

Card: `LAB-ACTS-AS-TBACKEND-OUTBOX-CONTRACT-P5`
Status: implementation landed - no DB table, no job dependency
Date: 2026-07-03
Author: Codex

## 0. Scope and authority

This slice defines the first outbox contract for `acts-as-tbackend` without
forcing any Rails app to adopt a particular persistence or job system.

- No RubyGems publish.
- No Hub/Spark/Avenlance changes.
- No Sidekiq/ActiveJob dependency.
- No adapter read authority.
- No migration generator.

The adapter ships only a persistence-agnostic intent envelope plus a single
flush helper. Apps own where intents are stored, when they are retried, and what
operator UI or metrics they emit.

## 1. What belongs in the gem

Implemented:

| Surface | File | Role |
| --- | --- | --- |
| `ActsAsTbackend::OutboxIntent` | `lib/acts_as_tbackend/outbox_intent.rb` | Plain Ruby value object for a deterministic fact mirror intent. |
| `ActsAsTbackend::OutboxFlusher` | `lib/acts_as_tbackend/outbox_flusher.rb` | Flush one intent through `client.write_fact_once` and map the soft result into outbox statuses. |

Not implemented:

- ActiveRecord model/concern;
- migration/table generator;
- Sidekiq/ActiveJob worker;
- durable retry scheduler;
- app metrics.

That split keeps the gem small and lets a Rails app persist `intent.to_h` in an
existing outbox table, queue, JSON column, or test fixture.

## 2. Minimal intent shape

`OutboxIntent#to_h` is the storage contract:

```ruby
{
  "id" => "orders:42:order.accepted:1780387174500000",
  "fact" => {
    "id" => "orders:42:order.accepted:1780387174500000",
    "store" => "orders",
    "key" => "orders:42",
    "value" => { "status" => "accepted" },
    "transaction_time" => 1780387174.5,
    "schema_version" => 1,
    "producer" => "acts-as-tbackend"
  },
  "attempts" => 0,
  "last_status" => nil,
  "last_error" => nil
}
```

Rules:

- `id` defaults to `fact["id"]`.
- `fact` must include `id`, `store`, `key`, and `value`.
- `value_hash` is still omitted; the daemon canonical hash remains authority.
- `attempts`, `last_status`, and `last_error` are advisory fields for app-owned
  persistence. `OutboxFlusher.flush` returns a new intent with attempts
  incremented; the app decides whether to persist it.

## 3. Deterministic ids across retries

`OutboxIntent.from_record(...)` delegates to `Mirror.build_fact(...)`, which
uses `Fact.derive_id(store:, record_id:, event_type:, source_version:)`.

That means:

- retrying the same persisted intent sends the same fact id;
- daemon `committed_acked` means first insert;
- daemon `idempotent_replay` means the retry reached an already-committed fact;
- daemon `duplicate_fact_id_conflict` means the same id was reused for
  different content and should not be retried blindly.

Apps may also build a fact themselves and call `OutboxIntent.new(fact:)`; the
same validation and serialization contract applies.

## 4. Flusher API

```ruby
intent = ActsAsTbackend::OutboxIntent.from_record(
  record: order,
  store: "orders",
  event_type: "order.accepted",
  except: %i[created_at updated_at]
)

# Persist `intent.to_h` in app-owned storage.
restored = ActsAsTbackend::OutboxIntent.from_h(intent.to_h)
result = ActsAsTbackend::OutboxFlusher.flush(restored, client: ActsAsTbackend.client)

case result[:status]
when "inserted", "replay"
  # mark done
when "retryable", "unknown"
  # persist result[:intent].to_h and retry later
when "conflict", "failed"
  # terminal failure / operator review
end
```

`OutboxFlusher.flush` calls `client.write_fact_once`, not
`write_fact_once_safe`. The worker owns retry timing; the adapter does not loop
inside the flush call.

Return shape:

```ruby
{
  ok: true_or_false,
  status: "inserted",
  terminal: true_or_false,
  retryable: true_or_false,
  intent: updated_intent,
  result: raw_client_result
}
```

## 5. Status mapping

| Client status | Outbox status | terminal | retryable | Meaning |
| --- | --- | --- | --- | --- |
| `committed_acked` | `inserted` | true | false | First daemon insert completed. |
| `idempotent_replay` | `replay` | true | false | Safe success; this intent was already committed. |
| `duplicate_fact_id_conflict` | `conflict` | true | false | Same deterministic id, different content; operator/code issue. |
| `unavailable` | `retryable` | false | true | Daemon was not reached; retry later. |
| `circuit_open` | `retryable` | false | true | Client breaker is open; retry later. |
| `rejected_before_commit` | `retryable` | false | true | Daemon rejected before commit, usually overload; retry later. |
| `timeout_unknown` | `unknown` | false | true | Do not infer commit; retry with same deterministic id. |
| other retryable result | `retryable` | false | true | Preserve retry posture. |
| other non-retryable result | `failed` | true | false | Terminal failure unless app has a custom policy. |

`timeout_unknown` is deliberately separate from `retryable`: the next retry is
safe only because the fact id is deterministic. It may come back as
`idempotent_replay`.

## 6. Tests

Implemented unit coverage:

- intent from record preserves deterministic fact id;
- `to_h` / `from_h` round-trip for app-owned storage;
- required fact envelope validation;
- flush maps `committed_acked`, `idempotent_replay`,
  `duplicate_fact_id_conflict`, `unavailable`, and `timeout_unknown`;
- flush records attempts/last status and calls `write_fact_once`;
- no daemon required; tests use P4 `TestHelpers.fake_client`.

## 7. What app code still owns

Apps still need to decide:

- where to persist `intent.to_h`;
- how to lock/dequeue intents;
- retry schedule and max attempts;
- dead-letter/operator handling;
- metrics and dashboards;
- whether to wire Sidekiq, ActiveJob, a cron job, or an existing outbox worker.

That is intentional. The gem now defines the contract and status vocabulary
without becoming a job framework.
