# frozen_string_literal: true

require_relative "test_helper"

class HealthTest < Minitest::Test
  def base_config(token: nil)
    config = ActsAsTbackend::Config.new
    config.host = "127.0.0.1"
    config.port = 7401
    config.token = token
    config
  end

  def test_health_maps_ok
    client = TestSupport.client_with_ping_result(
      base_config, { ok: true, status: "ok", committed: nil, retryable: false, response: {}, error: nil }
    )

    health = client.health

    assert_equal "ok", health[:status]
    assert health[:ok]
    assert_nil health[:error]
  end

  def test_health_maps_down_without_raising
    config = base_config
    config.port = TestSupport.closed_port
    config.connect_timeout = 0.3
    client = ActsAsTbackend::Client.new(config)

    health = client.health

    assert_equal "down", health[:status]
    refute health[:ok]
  ensure
    client&.shutdown
  end

  def test_health_maps_circuit_open_without_raising
    config = base_config
    config.port = TestSupport.closed_port
    config.connect_timeout = 0.3
    config.breaker_threshold = 1
    config.breaker_cooldown = 30
    client = ActsAsTbackend::Client.new(config)

    client.ping # failure 1 -> breaker opens
    health = client.health

    assert_equal "circuit_open", health[:status]
    refute health[:ok]
  ensure
    client&.shutdown
  end

  def test_health_maps_auth_error
    client = TestSupport.client_with_ping_result(
      base_config,
      { ok: false, status: "error", committed: nil, retryable: nil, response: nil,
        error: "Authentication failed: invalid token" }
    )

    health = client.health

    assert_equal "auth_error", health[:status]
    refute health[:ok]
  end

  def test_health_maps_generic_error
    client = TestSupport.client_with_ping_result(
      base_config,
      { ok: false, status: "error", committed: nil, retryable: nil, response: nil, error: "Unknown operation: ping2" }
    )

    health = client.health

    assert_equal "error", health[:status]
  end

  def test_health_maps_config_error_without_raising
    config = base_config
    client = ActsAsTbackend::Client.new(config)
    # Force an unexpected exception inside `ping` to prove `health` never lets
    # it escape (a config-level bug should classify, not crash health checks).
    client.define_singleton_method(:ping) { raise ArgumentError, "boom" }

    health = client.health

    assert_equal "config_error", health[:status]
    refute health[:ok]
    assert_equal "boom", health[:error]
  end

  def test_health_reports_disabled_without_pinging
    config = base_config
    config.enabled = false
    client = ActsAsTbackend::Client.new(config)
    client.define_singleton_method(:ping) { raise "must not be called" }

    health = client.health

    assert_equal "disabled", health[:status]
    assert health[:ok]
  end

  def test_health_redacts_token_from_error_text
    client = TestSupport.client_with_ping_result(
      base_config(token: "super-secret-token"),
      { ok: false, status: "error", committed: nil, retryable: nil, response: nil,
        error: "unexpected failure near super-secret-token boundary" }
    )

    health = client.health

    refute_includes health[:error], "super-secret-token"
    assert_includes health[:error], "[REDACTED]"
  end

  def test_health_never_includes_a_raw_token_field
    client = TestSupport.client_with_ping_result(
      base_config(token: "super-secret-token"),
      { ok: true, status: "ok", committed: nil, retryable: false, response: {}, error: nil }
    )

    health = client.health

    refute health.key?(:token)
    refute health.values.any? { |v| v.to_s.include?("super-secret-token") }
  end

  def test_health_reports_config_summary_fields
    config = base_config
    config.durability_default = "durable"
    config.strict = true
    config.failure_policy = "warn"
    client = TestSupport.client_with_ping_result(
      config, { ok: true, status: "ok", committed: nil, retryable: false, response: {}, error: nil }
    )

    health = client.health

    assert_equal true, health[:enabled]
    assert_equal "127.0.0.1", health[:host]
    assert_equal 7401, health[:port]
    assert_equal "durable", health[:durability_default]
    assert_equal true, health[:strict]
    assert_equal "warn", health[:failure_policy]
  end

  def test_module_level_health_delegates_to_client
    assert_equal ActsAsTbackend.client.health.keys.sort, ActsAsTbackend.health.keys.sort
  end
end
