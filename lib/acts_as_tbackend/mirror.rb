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

    def build_fact(record:, store:, event_type:, only: nil, except: nil, tombstone: false, valid_time: nil)
      store = store.to_s
      record_id = record.id
      value = tombstone ? { "_tombstone" => true } : select_value(record, only: only, except: except)

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

    # Build + idempotent bounded-safe write. Soft/non-fatal: returns the client's soft
    # result and never raises for a down daemon unless `config.strict`.
    def mirror!(record:, store:, event_type:, **opts)
      return disabled_result unless ActsAsTbackend.enabled?

      fact = build_fact(record: record, store: store, event_type: event_type, **opts)
      ActsAsTbackend.client.write_fact_once_safe(fact)
    end

    def select_value(record, only:, except:)
      attrs = stringify(record.attributes)
      if only
        attrs.slice(*Array(only).map(&:to_s))
      elsif except
        attrs.except(*Array(except).map(&:to_s))
      else
        attrs
      end
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

    def stringify(hash)
      hash.each_with_object({}) { |(k, v), out| out[k.to_s] = v }
    end

    def disabled_result
      { ok: true, status: "disabled", committed: nil, retryable: false, response: nil, error: nil }
    end
  end
end
