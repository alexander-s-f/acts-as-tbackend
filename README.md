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
| **Extension** | `lib/acts_as_tbackend/extension.rb` | optional ActiveRecord macro, loaded explicitly by Rails apps. |

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
