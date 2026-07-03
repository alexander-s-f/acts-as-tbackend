# frozen_string_literal: true

require_relative "acts_as_tbackend/version"
require_relative "acts_as_tbackend/config"
require_relative "acts_as_tbackend/circuit_breaker"
require_relative "acts_as_tbackend/fact"
require_relative "acts_as_tbackend/sanitizer"
require_relative "acts_as_tbackend/connection"
require_relative "acts_as_tbackend/pool"
require_relative "acts_as_tbackend/client"
require_relative "acts_as_tbackend/failure_policy"
require_relative "acts_as_tbackend/mirror"
require_relative "acts_as_tbackend/outbox_intent"
require_relative "acts_as_tbackend/outbox_flusher"

# Production connector for the TBackend temporal-ledger daemon.
#
#   ActsAsTbackend.configure do |c|
#     c.host = "127.0.0.1"; c.port = 7401
#     c.token = ENV["TBACKEND_TOKEN"]
#     c.pool_size = 12                 # ≈ Puma threads/process
#   end
#
#   id   = ActsAsTbackend::Fact.derive_id(store: "orders", record_id: o.id,
#                                          event_type: "order.accepted", source_version: o.updated_at)
#   fact = ActsAsTbackend::Fact.build(id:, store: "orders", key: "order:#{o.id}", value: {...})
#   ActsAsTbackend.client.write_fact_once(fact)      # idempotent, pooled, circuit-broken
#
# Layers, deliberately separate:
#   Connection — one persistent framed socket + protocol (not thread-safe)
#   Pool       — N connections, checkout per thread (connection_pool)
#   Client     — facade: pool + circuit breaker; the app-facing API
module ActsAsTbackend
  class << self
    def config
      @config ||= Config.new
    end

    # Master kill-switch (Config#enabled). When false the extension callbacks no-op.
    def enabled?
      config.enabled
    end

    def configure
      yield config
      reset!
      config
    end

    # Shared pooled client. Thread-safe; memoized per process.
    def client
      @client ||= Client.new(config)
    end

    # Safe introspection - see Client#health. Never raises.
    def health
      client.health
    end

    # Rebuild pool + client. Call in the forking hook (Puma `on_worker_boot`,
    # Sidekiq `configure_server`) so a child never inherits a parent's sockets.
    def reset!
      old = @client
      @client = nil
      old&.shutdown
      nil
    end
  end
end
