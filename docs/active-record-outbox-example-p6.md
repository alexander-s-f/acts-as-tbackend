# ActiveRecord Outbox Example (P6)

Card: `LAB-ACTS-AS-TBACKEND-OUTBOX-AR-EXAMPLE-P6`
Status: example only - app-owned table/model/worker
Date: 2026-07-03
Author: Codex

## 0. Scope and authority

This is a Rails application example for the P5 outbox contract. It is not loaded
by the gem and does not add an ActiveRecord, ActiveJob, or Sidekiq dependency.

- Rails/Postgres stays the application authority.
- TBackend remains shadow evidence unless a later gate changes that posture.
- The app owns the outbox table, locking, retry schedule, dead-letter handling,
  metrics, and worker runtime.
- `acts-as-tbackend` only provides `OutboxIntent` and `OutboxFlusher`.

## 1. Example migration

```ruby
class CreateTbackendOutboxIntents < ActiveRecord::Migration[7.1]
  def change
    create_table :tbackend_outbox_intents do |t|
      t.string :intent_id, null: false
      t.jsonb :payload, null: false, default: {}
      t.string :status, null: false, default: "pending"
      t.integer :attempts, null: false, default: 0
      t.string :last_status
      t.text :last_error
      t.datetime :next_attempt_at
      t.datetime :locked_at
      t.datetime :flushed_at
      t.timestamps
    end

    add_index :tbackend_outbox_intents, :intent_id, unique: true
    add_index :tbackend_outbox_intents, [:status, :next_attempt_at]
    add_index :tbackend_outbox_intents, :locked_at
  end
end
```

For non-Postgres adapters, use the local JSON column type instead of `jsonb`.
Keep the unique `intent_id` index: it is what makes duplicate enqueue attempts
collapse to the same deterministic mirror intent.

## 2. Example model

```ruby
class TbackendOutboxIntent < ApplicationRecord
  self.table_name = "tbackend_outbox_intents"

  RETRYABLE_STATUSES = %w[pending retryable unknown].freeze
  TERMINAL_STATUSES = %w[done conflict failed].freeze

  scope :ready, lambda {
    where(status: RETRYABLE_STATUSES)
      .where("next_attempt_at IS NULL OR next_attempt_at <= ?", Time.current)
      .where("locked_at IS NULL OR locked_at < ?", 5.minutes.ago)
  }

  def self.enqueue_record!(record:, store:, event_type:, **mirror_opts)
    intent = ActsAsTbackend::OutboxIntent.from_record(
      record: record,
      store: store,
      event_type: event_type,
      **mirror_opts
    )

    row = find_or_initialize_by(intent_id: intent.id)
    if row.persisted? && row.payload != intent.to_h
      raise ArgumentError, "tbackend intent_id reused with different payload: #{intent.id}"
    end

    row.payload = intent.to_h
    row.status = "pending" if row.new_record?
    row.attempts ||= 0
    row.save!
    row
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  def intent
    ActsAsTbackend::OutboxIntent.from_h(payload)
  end

  def terminal?
    TERMINAL_STATUSES.include?(status)
  end

  def apply_flush!(flush, now: Time.current)
    updated_intent = flush.fetch(:intent)

    self.payload = updated_intent.to_h
    self.attempts = updated_intent.attempts
    self.last_status = flush.fetch(:status)
    self.last_error = updated_intent.last_error
    self.locked_at = nil

    case flush.fetch(:status)
    when "inserted", "replay"
      self.status = "done"
      self.flushed_at = now
      self.next_attempt_at = nil
    when "retryable", "unknown"
      self.status = flush.fetch(:status)
      self.next_attempt_at = now + retry_delay
    when "conflict", "failed"
      self.status = flush.fetch(:status)
      self.next_attempt_at = nil
    else
      self.status = "failed"
      self.next_attempt_at = nil
    end

    save!
  end

  private

  def retry_delay
    [attempts, 10].min.minutes
  end
end
```

The enqueue method is intentionally idempotent. `OutboxIntent.from_record`
derives the same fact id for the same record/event/source version, and
`intent_id` stores that id. If the same id appears with different content, treat
it as a code or data issue instead of silently overwriting the row.

One app-owned callback shape:

```ruby
class Order < ApplicationRecord
  after_commit :enqueue_tbackend_outbox, on: %i[create update]

  private

  def enqueue_tbackend_outbox
    TbackendOutboxIntent.enqueue_record!(
      record: self,
      store: "orders",
      event_type: "order.changed",
      except: %i[created_at updated_at]
    )
  end
end
```

## 3. Example flusher service

```ruby
class FlushTbackendOutboxIntent
  def self.call(row, client: ActsAsTbackend.client, now: Time.current)
    claimed_intent = nil

    row.with_lock do
      return { ok: true, status: "skipped_terminal" } if row.terminal?
      return { ok: true, status: "skipped_locked" } if row.locked_at && row.locked_at > 5.minutes.ago

      row.update!(locked_at: now)
      claimed_intent = row.intent
    end

    flush = ActsAsTbackend::OutboxFlusher.flush(claimed_intent, client: client)

    row.with_lock do
      row.apply_flush!(flush, now: now)
    end

    flush
  rescue StandardError => e
    row.with_lock do
      row.update!(
        status: "retryable",
        last_error: "#{e.class}: #{e.message}",
        locked_at: nil,
        next_attempt_at: Time.current + 1.minute
      )
    end

    { ok: false, status: "retryable", terminal: false, retryable: true, error: e }
  end
end
```

For higher-volume Postgres workers, claim rows with `FOR UPDATE SKIP LOCKED` or
your existing outbox framework. The important contract is that each flush uses
the persisted `payload`, then stores `flush[:intent].to_h` so attempts and last
status survive process restarts.

## 4. Sidekiq-like pseudo-worker

```ruby
class TbackendOutboxWorker
  BATCH_SIZE = 100

  def perform
    TbackendOutboxIntent.ready.order(:id).limit(BATCH_SIZE).to_a.each do |row|
      FlushTbackendOutboxIntent.call(row)
    end
  end
end
```

This shape can run from Sidekiq, ActiveJob, a cron rake task, or an existing
application outbox runner. The gem does not require any of those systems.

## 5. Status mapping

| `OutboxFlusher` status | App row status | Retry? | Meaning |
| --- | --- | --- | --- |
| `inserted` | `done` | no | First daemon insert completed. |
| `replay` | `done` | no | The fact was already committed with the same id/content. |
| `retryable` | `retryable` | yes | Daemon/client was unavailable or rejected before commit. |
| `unknown` | `unknown` | yes | Timeout after an unknown commit point; retry with the same deterministic id. |
| `conflict` | `conflict` | no | Same deterministic id, different content; operator/code review. |
| `failed` | `failed` | no | Non-retryable adapter/client result. |

`timeout_unknown` deserves a visible state because it does not prove failure.
The safe recovery is to retry the exact same fact id; TBackend can then return
`idempotent_replay` if the first attempt actually committed.

## 6. Test sketch without Rails in the gem

Application tests can pass a fake client into the service while the gem test
suite remains plain Ruby:

```ruby
require "acts_as_tbackend/test_helpers"

fake = ActsAsTbackend::TestHelpers.fake_client
fake.queue_result(status: :timeout_unknown)
fake.queue_result(status: :idempotent_replay)

row = TbackendOutboxIntent.enqueue_record!(
  record: order,
  store: "orders",
  event_type: "order.changed",
  except: %i[created_at updated_at]
)

first = FlushTbackendOutboxIntent.call(row, client: fake)
expect(first[:status]).to eq("unknown")
expect(row.reload.status).to eq("unknown")

second = FlushTbackendOutboxIntent.call(row, client: fake)
expect(second[:status]).to eq("replay")
expect(row.reload.status).to eq("done")
```

The adapter-side tests still do not boot Rails or require a database; they only
verify the plain `OutboxIntent` and `OutboxFlusher` contract.
