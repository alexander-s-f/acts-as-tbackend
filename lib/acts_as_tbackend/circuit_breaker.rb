# frozen_string_literal: true

module ActsAsTbackend
  # A small thread-safe circuit breaker per (host, port). After `threshold`
  # consecutive failures it opens for `cooldown` seconds, then allows a single
  # half-open probe. Keeps a down daemon from stalling every request thread
  # (fail-fast) while a shadow write stays non-fatal.
  class CircuitBreaker
    def initialize(threshold:, cooldown:)
      @threshold = threshold
      @cooldown = cooldown
      @failures = 0
      @opened_at = nil
      @mutex = Mutex.new
    end

    def allow_request?
      @mutex.synchronize do
        return true if @opened_at.nil?
        return true if (monotonic - @opened_at) >= @cooldown # half-open probe

        false
      end
    end

    def record_success
      @mutex.synchronize do
        @failures = 0
        @opened_at = nil
      end
    end

    def record_failure
      @mutex.synchronize do
        @failures += 1
        @opened_at = monotonic if @failures >= @threshold
      end
    end

    def open?
      @mutex.synchronize { !@opened_at.nil? && (monotonic - @opened_at) < @cooldown }
    end

    private

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
