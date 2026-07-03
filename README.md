# acts-as-tbackend

Production Ruby connector for the **TBackend** temporal-ledger daemon: pooled,
circuit-broken, idempotent writes over the framed loopback protocol. Built for
multi-threaded Rails (Puma) — persistent sockets, a connection pool sized to the
worker threads, and soft, non-fatal results when the daemon is down.

Status: connector is **prod-shaped**; TBackend itself stays a **shadow-ready**
side ledger (Rails/Postgres authoritative) until convergence + ops gates. See
`../igniter-tbackend/docs/tbackend-onboarding.md`.

Canonical repository:

```text
https://github.com/alexander-s-f/acts-as-tbackend
```

Forgejo may mirror this repository for internal navigation, but GitHub is the
team-facing source and RubyGems is the package authority.

## Layers (deliberately separate)

| Layer | File | Responsibility |
| --- | --- | --- |
| **Connection** | `lib/acts_as_tbackend/connection.rb` | one persistent framed socket + protocol (token, `write_fact_once`, rich status mapping, reconnect). **Not thread-safe.** |
| **Pool** | `lib/acts_as_tbackend/pool.rb` | N connections, checkout per thread (`connection_pool`). The concurrency layer. |
| **Client** | `lib/acts_as_tbackend/client.rb` | app-facing facade: pool + circuit breaker. |
| **Fact** | `lib/acts_as_tbackend/fact.rb` | deterministic derived ids + fact builder. |
| **Config** | `lib/acts_as_tbackend/config.rb` | host/port/token/timeouts/pool size/durability (ENV-defaulted). |
| **Mirror** | `lib/acts_as_tbackend/mirror.rb` | plain-Ruby record to fact envelope + soft `write_fact_once_safe`. |
| **Sanitizer** | `lib/acts_as_tbackend/sanitizer.rb` | plain-Ruby attribute filter (`only`/`except`/`denylist`), used by Mirror. |
| **FailurePolicy** | `lib/acts_as_tbackend/failure_policy.rb` | named policy for a soft mirror failure: `ignore` / `warn` / `raise_in_test` / `enqueue_retry` (reserved). |
| **Extension** | `lib/acts_as_tbackend/extension.rb` | optional ActiveRecord macro, loaded explicitly by Rails apps. |
| **TestHelpers** | `lib/acts_as_tbackend/test_helpers.rb` | opt-in (`require "acts_as_tbackend/test_helpers"`) fake client + assertion helpers for app test suites. |

## Usage

```ruby
ActsAsTbackend.configure do |c|
  c.host = "127.0.0.1"; c.port = 7401
  c.token = ENV["TBACKEND_TOKEN"]     # sent on every request when set
  c.pool_size = 12                    # ≈ Puma threads per process
  c.durability_default = "accepted"   # or "durable" (group-commit fdatasync)
end

# Deterministic id → a retry is an idempotent replay, not a duplicate.
id   = ActsAsTbackend::Fact.derive_id(store: "orders", record_id: order.id,
                                      event_type: "order.accepted", source_version: order.updated_at)
fact = ActsAsTbackend::Fact.build(id:, store: "orders", key: "order:#{order.id}",
                                  value: { status: "accepted" }, valid_time: order.scheduled_at)

result = ActsAsTbackend.client.write_fact_once(fact)
# => { ok:, status:, committed:, retryable:, response:, error: }
#    status ∈ committed_acked | idempotent_replay | duplicate_fact_id_conflict
#             | rejected_before_commit | timeout_unknown | unavailable | circuit_open

ActsAsTbackend.client.facts_by_seq(store: "orders", after_seq: 0)   # clock-free ordered read
ActsAsTbackend.client.latest_for(store: "orders", key: "order:42")  # point-in-time
```

Reads/writes never raise for a down daemon (unless `strict`) — they return a soft
result so a shadow write stays non-fatal, and the circuit breaker fails fast while
the daemon is unreachable.

## Rails mirror

The core `require "acts_as_tbackend"` stays ActiveRecord-free. Rails apps opt into
the macro by requiring the extension:

```ruby
require "acts_as_tbackend/extension"

class Order < ApplicationRecord
  acts_as_tbackend store: "orders", except: %i[created_at updated_at]
end
```

The callback path is intentionally synchronous and soft for v0:

```text
after_commit -> Mirror.build_fact -> client.write_fact_once_safe
```

If the daemon is down, the write returns a soft result such as
`status: "unavailable"` or `status: "circuit_open"` and the Rails request path is
not raised by default. For heavier paths, call `record.tbackend_fact(...)` or
`ActsAsTbackend::Mirror.mirror!(...)` from an app-owned background job.

## Health check

`ActsAsTbackend.health` (or `client.health`) never raises — safe to wire into a
Rails health-check endpoint or a rake task unconditionally, regardless of
`config.strict`:

```ruby
ActsAsTbackend.health
# => { enabled: true, host: "127.0.0.1", port: 7401, durability_default: "accepted",
#      strict: false, failure_policy: "ignore",
#      ok: true, status: "ok", error: nil }
#    status ∈ ok | down | circuit_open | auth_error | config_error | disabled | error
```

The token is never included as a field, and any token substring is redacted out
of `error` text before it's returned.

## Failure policy

`config.failure_policy` names what happens, in addition to the soft result
itself, when a mirror write soft-fails (a successful `disabled`/`committed_acked`/
`idempotent_replay` never triggers it):

```ruby
ActsAsTbackend.configure { |c| c.failure_policy = "warn" }
```

| Policy | Behavior |
| --- | --- |
| `ignore` (default) | No extra action — soft result only, exactly today's behavior. |
| `warn` | Also `warn(...)` a one-line description (store/event_type/status/error). |
| `raise_in_test` | Also raises `ActsAsTbackend::MirrorFailure` — but **only** when `RAILS_ENV`/`RACK_ENV` is `"test"` (or `TBACKEND_FORCE_TEST_MODE=1`). Never in production, so it's safe to leave set in shared config. |
| `enqueue_retry` | Reserved for a future outbox worker (P5+). Accepted now so apps can name their intent; **no retry/enqueue behavior exists yet** — it currently behaves like `ignore`. |

## Test helpers

`require "acts_as_tbackend/test_helpers"` (opt-in — not loaded by the core
entrypoint) for testing app code that calls `ActsAsTbackend.client` or
`Mirror.mirror!` without a live daemon:

```ruby
require "acts_as_tbackend/test_helpers"

ActsAsTbackend::TestHelpers.stub_client do |fake|
  fake.queue_result(status: :committed_acked, seq_id: 7)

  captured = ActsAsTbackend::TestHelpers.capture_mirror_result(
    record: order, store: "orders", event_type: "order.accepted"
  )

  ActsAsTbackend::TestHelpers.assert_tbackend_fact(
    captured[:fact], store: "orders", value_includes: { "status" => "accepted" }
  )
  assert_equal "committed_acked", captured[:result][:status]
end
```

`fake.queue_result(status:)` accepts any real daemon status —
`committed_acked`, `idempotent_replay`, `duplicate_fact_id_conflict`,
`unavailable`, `timeout_unknown`, `circuit_open` — with sane `ok`/`committed`/
`retryable` defaults per status; pass extra kwargs to override any field.
`fake.calls` records every call made (method, args, kwargs) for assertions.

## Outbox contract

For heavier write paths, keep TBackend off the request path by storing a
persistence-agnostic intent and flushing it from app-owned infrastructure:

```ruby
intent = ActsAsTbackend::OutboxIntent.from_record(
  record: order,
  store: "orders",
  event_type: "order.accepted",
  except: %i[created_at updated_at]
)

# Persist this in your own outbox table/queue/JSON column.
payload = intent.to_h

# Later, in your own worker:
restored = ActsAsTbackend::OutboxIntent.from_h(payload)
flush = ActsAsTbackend::OutboxFlusher.flush(restored, client: ActsAsTbackend.client)

case flush[:status]
when "inserted", "replay"
  # mark done
when "retryable", "unknown"
  # retry later with flush[:intent].to_h
when "conflict", "failed"
  # operator review / dead-letter
end
```

`OutboxFlusher` calls `write_fact_once` once and maps the soft result; it does
not create a database table, enqueue a job, or run an internal retry loop. A
`timeout_unknown` stays retryable-but-unknown: retrying is safe because the fact
id is deterministic, and the daemon may answer `idempotent_replay` next time.

For an app-owned ActiveRecord table/model/worker shape, see
[`docs/active-record-outbox-example-p6.md`](docs/active-record-outbox-example-p6.md).

## Shadow without authority

The recipe for adding this gem to a Rails app **without** making TBackend an
authority over anything:

```ruby
ActsAsTbackend.configure do |c|
  c.host = "127.0.0.1"; c.port = 7401   # loopback or a private daemon only
  c.strict = false                       # NEVER raise into the request path
  c.durability_default = "accepted"      # page-cache ack; a shadow write isn't a commit record
  c.failure_policy = "ignore"            # a down daemon must not surface as an app error
end

class Order < ApplicationRecord
  # Triple guard: (1) `enabled` kill-switch, (2) `strict: false` never raises,
  # (3) sample instead of mirroring every write if volume is a concern.
  acts_as_tbackend store: "orders", except: %i[created_at updated_at]

  after_commit :maybe_mirror, on: %i[create update]

  private

  def maybe_mirror
    return unless rand < 0.1 # sampling — mirror only 10% of writes, if desired

    mirror_tbackend(event_type: "sampled")
  end
end
```

- **Rails/Postgres stay authoritative.** Nothing reads from TBackend to make a
  business decision; `tbackend_history`/`tbackend_latest_for` are for
  observability/debugging only.
- **A soft result is evidence, not a receipt.** `status: "committed_acked"`
  means the daemon accepted the write — it does not mean the business
  transaction is safe, correct, or even still true (TBackend has no read
  authority in this posture).
- **Never let a shadow write become a hard dependency.** `strict: false` (the
  default) + `failure_policy: "ignore"` or `"warn"` (never `"raise_in_test"`
  outside test, and never anything that raises in production) keeps a
  completely down daemon invisible to the app's own request path.
- **Watch `ActsAsTbackend.health`**, not the mirror's return value, for
  operational visibility — a dashboard/rake task polling `health[:status]`
  is the intended way to notice "TBackend has been down for an hour," not
  scraping mirror results out of application logs.

## Fork-safety (Puma / Sidekiq)

Sockets created before a fork are invalid in the child. Reset in the forking hook:

```ruby
# config/puma.rb
on_worker_boot { ActsAsTbackend.reset! }
# Sidekiq
Sidekiq.configure_server { |cfg| cfg.on(:startup) { ActsAsTbackend.reset! } }
```

## Throughput

Persistent pooled sockets + `TCP_NODELAY` make 5–8k rpm (≈83–133 rps) modest. The
daemon sheds load past `max_inflight_requests` with a retryable `overloaded` →
`rejected_before_commit`, which `write_fact_once_safe` retries with backoff. A live
load test proving the number (and finding the ceiling) is the next step.

## Legacy files

`shadow_comparison.rb`, `demo.rb`, and `verify_shadow.rb` are retained as
pre-refresh reference material for the shadow-parity/demo layer. They are not
loaded by the core entrypoint and still need a separate port if that layer becomes
active again.

The refreshed core + optional Rails mirror are the supported v0 surface.
