# frozen_string_literal: true

module ActsAsTbackend
  # Persistence-agnostic mirror intent for app-owned outbox tables/queues.
  #
  # The adapter deliberately does not create a DB table or depend on ActiveJob /
  # Sidekiq. Apps can persist `intent.to_h` in whatever outbox they already use,
  # then rebuild with `OutboxIntent.from_h` before flushing.
  class OutboxIntent
    REQUIRED_FACT_KEYS = %w[id store key value].freeze

    attr_reader :id, :fact, :attempts, :last_status, :last_error

    def self.from_record(record:, store:, event_type:, **mirror_opts)
      new(fact: Mirror.build_fact(record: record, store: store, event_type: event_type, **mirror_opts))
    end

    def self.from_h(hash)
      h = stringify(hash)
      new(
        id: h["id"],
        fact: h.fetch("fact"),
        attempts: h.fetch("attempts", 0),
        last_status: h["last_status"],
        last_error: h["last_error"]
      )
    end

    def self.stringify(hash)
      hash.each_with_object({}) { |(k, v), out| out[k.to_s] = normalize(v) }
    end

    def self.normalize(value)
      case value
      when Hash
        stringify(value)
      when Array
        value.map { |v| normalize(v) }
      else
        value
      end
    end

    def initialize(fact:, id: nil, attempts: 0, last_status: nil, last_error: nil)
      @fact = stringify(fact)
      validate_fact!(@fact)
      @id = (id || intent_id(@fact)).to_s
      @attempts = Integer(attempts)
      @last_status = last_status
      @last_error = last_error
    end

    def to_h
      {
        "id" => id,
        "fact" => deep_dup(fact),
        "attempts" => attempts,
        "last_status" => last_status,
        "last_error" => last_error
      }
    end

    def record_result(result)
      self.class.new(
        id: id,
        fact: fact,
        attempts: attempts + 1,
        last_status: result[:status],
        last_error: result[:error]
      )
    end

    private

    def intent_id(fact)
      fact.fetch("id")
    end

    def validate_fact!(fact)
      missing = REQUIRED_FACT_KEYS.reject { |key| fact.key?(key) }
      return if missing.empty?

      raise ArgumentError, "outbox fact missing required key(s): #{missing.join(', ')}"
    end

    def stringify(hash)
      self.class.stringify(hash)
    end

    def normalize(value)
      self.class.normalize(value)
    end

    def deep_dup(value)
      normalize(value)
    end
  end
end
