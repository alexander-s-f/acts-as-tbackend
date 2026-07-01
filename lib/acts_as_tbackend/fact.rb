# frozen_string_literal: true

require "json"

module ActsAsTbackend
  # Builds facts with a **deterministic, domain-derived id** so a retry re-sends the
  # same id and collapses to an idempotent replay instead of a duplicate.
  #
  # NEVER put wall-clock in the id. Derive it from the source record's own version
  # stamp (e.g. `updated_at`), which is stable across retries and advances on every
  # real edit. The observation wall-clock belongs in `transaction_time` only.
  #
  #   id = ActsAsTbackend::Fact.derive_id(
  #     store: "orders", record_id: order.id, event_type: "order.accepted",
  #     source_version: order.updated_at)
  #   fact = ActsAsTbackend::Fact.build(
  #     id:, store: "orders", key: "order:#{order.id}", value: {...},
  #     valid_time: order.scheduled_at)
  module Fact
    module_function

    # Deterministic occurrence id. Components must be colon-free (the ":" is the id
    # separator); source_version is normalised to a colon-free token.
    def derive_id(store:, record_id:, event_type:, source_version:)
      "#{store}:#{record_id}:#{event_type}:#{version_token(source_version)}"
    end

    # A Time is encoded as an integer microsecond epoch — fully deterministic
    # (no float formatting) and colon-free. Anything else is used as-is (stringified).
    def version_token(source_version)
      if source_version.respond_to?(:usec) && source_version.respond_to?(:to_i)
        source_version.to_i * 1_000_000 + source_version.usec
      else
        source_version.to_s
      end
    end

    # Builds a fact envelope. `value_hash` is intentionally omitted: the daemon
    # stamps its own canonical hash on write_fact_once and is the authority.
    def build(id:, store:, key:, value:, valid_time: nil, transaction_time: nil,
              causation: nil, schema_version: 1, producer: nil)
      fact = {
        "id" => id,
        "store" => store.to_s,
        "key" => key.to_s,
        "value" => value,
        "transaction_time" => (transaction_time || now).to_f,
        "schema_version" => schema_version
      }
      fact["valid_time"] = valid_time.to_f unless valid_time.nil?
      fact["causation"] = causation unless causation.nil?
      fact["producer"] = producer unless producer.nil?
      fact
    end

    def now
      Process.clock_gettime(Process::CLOCK_REALTIME)
    end
  end
end
