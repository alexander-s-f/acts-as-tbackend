# frozen_string_literal: true

require "connection_pool"

module ActsAsTbackend
  # A pool of persistent Connections — the concurrency layer, kept deliberately
  # separate from the Connection (protocol) so each can be reasoned about and tested
  # on its own. Sized to the process's worker threads (≈ Puma `threads`).
  #
  # Fork-safety: sockets created before a fork are invalid in the child. Call
  # `ActsAsTbackend.reset!` in the forking hook (Puma `on_worker_boot`, Sidekiq
  # `on(:startup)`) so children build fresh connections.
  class Pool
    def initialize(config)
      @pool = ConnectionPool.new(size: config.pool_size, timeout: config.pool_checkout_timeout) do
        Connection.new(
          host: config.host, port: config.port, token: config.token,
          connect_timeout: config.connect_timeout, request_timeout: config.request_timeout,
          durability_default: config.durability_default, strict: config.strict
        )
      end
    end

    def with(&block)
      @pool.with(&block)
    end

    def shutdown
      @pool.shutdown { |conn| conn.close }
    end
  end
end
