# frozen_string_literal: true

require "time"

module ActsAsTbackend
  # Plain-Ruby record -> fact mirror, deliberately independent of ActiveSupport so it
  # is unit-testable without Rails. The AR Extension delegates here; an app can also
  # call `mirror!` directly from its own background job.
  #
  # A "record" is any object that responds to `#id`, `#attributes` (a Hash), and
  # ideally `#updated_at` (used as the deterministic id version — a retry re-sends the
  # same id and collapses to an idempotent replay).
  module Mirror
    module_function

    def build_fact(record:, store:, event_type:, only: nil, except: nil, denylist: nil, tombstone: false, valid_time: nil)
      store = store.to_s
      record_id = record.id
      value = tombstone ? { "_tombstone" => true } : select_value(record, only: only, except: except, denylist: denylist)

      Fact.build(
        id: Fact.derive_id(store: store, record_id: record_id, event_type: event_type,
                           source_version: source_version(record)),
        store: store,
        key: "#{store}:#{record_id}",
        value: value,
        valid_time: valid_time || record_valid_time(record),
        causation: "#{store}:#{record_id}:#{event_type}",
        producer: ActsAsTbackend.config.producer
      )
    end

    # Build + idempotent bounded-safe write. Soft/non-fatal by default: returns
    # the client's soft result. `config.failure_policy` decides whether a soft
    # failure ALSO warns or raises (`raise_in_test` only, never in production)
    # - see FailurePolicy. The result itself is unchanged either way.
    def mirror!(record:, store:, event_type:, **opts)
      return disabled_result unless ActsAsTbackend.enabled?

      fact = build_fact(record: record, store: store, event_type: event_type, **opts)
      result = ActsAsTbackend.client.write_fact_once_safe(fact)
      FailurePolicy.apply(result, context: { store: store, event_type: event_type })
    end

    # LAB-ACTS-AS-TBACKEND-ADAPTER-DX-P4: delegates to Sanitizer, which
    # preserves this exact only/except behavior; `denylist` is a new, opt-in
    # parameter (nil = no denylist applied, the pre-existing default).
    def select_value(record, only:, except:, denylist: nil)
      Sanitizer.call(record.attributes, only: only, except: except, denylist: denylist)
    end

    # A persisted version stamp, stable across retries; falls back to wall-clock only
    # when the record has none (then the id is best-effort, not retry-stable).
    def source_version(record)
      if record.respond_to?(:updated_at) && record.updated_at
        record.updated_at
      else
        Time.now
      end
    end

    def record_valid_time(record)
      record.respond_to?(:valid_time) ? record.valid_time : nil
    end

    def disabled_result
      { ok: true, status: "disabled", committed: nil, retryable: false, response: nil, error: nil }
    end
  end
end
