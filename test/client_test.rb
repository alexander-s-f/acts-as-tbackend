# frozen_string_literal: true

require_relative "test_helper"

class ClientTest < Minitest::Test
  def test_circuit_breaker_opens_after_threshold
    config = ActsAsTbackend::Config.new
    config.host = "127.0.0.1"
    config.port = TestSupport.closed_port
    config.pool_size = 1
    config.connect_timeout = 0.3
    config.breaker_threshold = 2
    config.breaker_cooldown = 30
    client = ActsAsTbackend::Client.new(config)

    assert_equal "unavailable", client.ping[:status]   # failure 1
    assert_equal "unavailable", client.ping[:status]   # failure 2 -> breaker opens
    result = client.ping                               # short-circuit, no socket touched

    assert_equal "circuit_open", result[:status]
    assert result[:retryable]
  ensure
    client&.shutdown
  end
end
