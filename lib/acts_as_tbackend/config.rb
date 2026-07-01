# frozen_string_literal: true

module ActsAsTbackend
  # Process-wide configuration for the TBackend connector. Defaults come from ENV so
  # the same code runs in dev / CI / prod without edits.
  #
  #   ActsAsTbackend.configure do |c|
  #     c.host = "127.0.0.1"; c.port = 7401
  #     c.token = ENV["TBACKEND_TOKEN"]
  #     c.pool_size = 12                 # ~ Puma threads per process
  #     c.durability_default = "accepted"
  #   end
  class Config
    attr_accessor :host, :port, :token,
                  :connect_timeout, :request_timeout,
                  :pool_size, :pool_checkout_timeout,
                  :durability_default, :strict,
                  # circuit breaker
                  :breaker_threshold, :breaker_cooldown,
                  # producer stamped onto facts built via Fact.build
                  :producer,
                  # master kill-switch for the mirror (extension callbacks no-op when false)
                  :enabled

    def initialize
      @enabled = ENV.fetch("TBACKEND_ENABLED", "1") != "0"
      @host = ENV.fetch("TBACKEND_HOST", "127.0.0.1")
      @port = Integer(ENV.fetch("TBACKEND_PORT", 7401))
      @token = ENV["TBACKEND_TOKEN"]
      @connect_timeout = Float(ENV.fetch("TBACKEND_CONNECT_TIMEOUT", 1.0))
      @request_timeout = Float(ENV.fetch("TBACKEND_REQUEST_TIMEOUT", 2.0))
      @pool_size = Integer(ENV.fetch("TBACKEND_POOL_SIZE", 5))
      @pool_checkout_timeout = Float(ENV.fetch("TBACKEND_POOL_CHECKOUT_TIMEOUT", 1.0))
      @durability_default = ENV.fetch("TBACKEND_DURABILITY", "accepted")
      @strict = ENV["TBACKEND_STRICT"] == "1"
      @breaker_threshold = Integer(ENV.fetch("TBACKEND_BREAKER_THRESHOLD", 5))
      @breaker_cooldown = Float(ENV.fetch("TBACKEND_BREAKER_COOLDOWN", 5.0))
      @producer = ENV.fetch("TBACKEND_PRODUCER", "acts-as-tbackend")
    end
  end
end
