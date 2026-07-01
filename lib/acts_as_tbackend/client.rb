# frozen_string_literal: true

module ActsAsTbackend
  # The app-facing facade: a pooled, circuit-broken TBackend client. Checks the
  # breaker, checks out a persistent Connection, delegates, and feeds transport
  # health back to the breaker. Thread-safe (the Pool serialises per connection).
  #
  #   ActsAsTbackend.client.write_fact_once(fact)
  #   ActsAsTbackend.client.facts_by_seq(store: "orders", after_seq: 0)
  #
  # Every method returns the Connection's soft result hash
  # ({ ok:, status:, committed:, retryable:, response:, error: }) — never raises for
  # a down daemon unless `config.strict` is set. When the breaker is open it
  # short-circuits with status "circuit_open" (retryable) without touching the socket.
  class Client
    WRITE_STATUSES_OK = %w[committed_acked idempotent_replay].freeze

    def initialize(config)
      @config = config
      @pool = Pool.new(config)
      @breaker = CircuitBreaker.new(threshold: config.breaker_threshold, cooldown: config.breaker_cooldown)
    end

    def write_fact_once(fact, **opts)
      call { |c| c.write_fact_once(fact, **opts) }
    end

    def write_fact_once_safe(fact, **opts)
      call { |c| c.write_fact_once_safe(fact, **opts) }
    end

    def latest_for(**opts)
      call { |c| c.latest_for(**opts) }
    end

    def facts_for(**opts)
      call { |c| c.facts_for(**opts) }
    end

    def facts_by_seq(**opts)
      call { |c| c.facts_by_seq(**opts) }
    end

    def ping(**opts)
      call { |c| c.ping(**opts) }
    end

    def shutdown
      @pool.shutdown
    end

    private

    def call
      return circuit_open_result unless @breaker.allow_request?

      begin
        result = @pool.with { |conn| yield conn }
      rescue Connection::TransportUnavailable, Connection::TransportUnknown => e
        # strict mode — Connection raised instead of soft-resulting.
        @breaker.record_failure
        raise e
      end

      transport_healthy?(result) ? @breaker.record_success : @breaker.record_failure
      result
    end

    # A completed round-trip (even a domain error like duplicate_fact_id_conflict) is
    # transport-healthy. Only connect/ack transport states trip the breaker.
    def transport_healthy?(result)
      !%w[unavailable timeout_unknown].include?(result[:status])
    end

    def circuit_open_result
      { ok: false, status: "circuit_open", committed: nil, retryable: true, response: nil,
        error: "TBackend circuit breaker open for #{@config.host}:#{@config.port}" }
    end
  end
end
