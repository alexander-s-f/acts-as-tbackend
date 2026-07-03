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

    # LAB-ACTS-AS-TBACKEND-ADAPTER-DX-P4: a safe introspection call - it never
    # raises (regardless of `config.strict`), even if the config itself is
    # broken (e.g. an unreachable/malformed host), so ops tooling and a Rails
    # health-check endpoint can call it unconditionally.
    #
    #   ActsAsTbackend.health
    #   # => { enabled:, host:, port:, durability_default:, strict:,
    #   #      failure_policy:, ok:, status:, error: }
    #   #    status ∈ ok | down | circuit_open | auth_error | config_error | disabled | error
    def health
      base = {
        enabled: @config.enabled,
        host: @config.host,
        port: @config.port,
        durability_default: @config.durability_default,
        strict: @config.strict,
        failure_policy: @config.failure_policy
      }
      return base.merge(ok: true, status: "disabled", error: nil) unless @config.enabled

      begin
        result = ping
      rescue StandardError => e
        return base.merge(ok: false, status: "config_error", error: redact(e.message))
      end

      base.merge(ok: result[:ok] == true, status: classify_ping(result), error: redact(result[:error]))
    end

    def shutdown
      @pool.shutdown
    end

    private

    def classify_ping(result)
      case result[:status]
      when "ok" then "ok"
      when "circuit_open" then "circuit_open"
      when "unavailable", "timeout_unknown" then "down"
      else
        auth_error?(result[:error]) ? "auth_error" : "error"
      end
    end

    # The daemon's auth middleware (igniter-tbackend `packs/auth.rs`) rejects
    # with a static "Authentication failed: ..." / "Access denied: ..."
    # message (never echoes the token) - classify on that, not an error_code
    # (the daemon does not set one for auth rejections).
    def auth_error?(error)
      return false if error.nil?

      text = error.to_s
      text.include?("Authentication failed") || text.include?("Access denied")
    end

    # Redacts `config.token` from any string that might contain it. Health
    # output has NO `token:` field to begin with, but error text is
    # server/exception-provided and untrusted - never assume it is clean.
    def redact(text)
      return nil if text.nil?

      text = text.to_s
      token = @config.token
      return text if token.nil? || token.to_s.empty?

      text.gsub(token.to_s, "[REDACTED]")
    end

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
