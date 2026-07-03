# frozen_string_literal: true

module ActsAsTbackend
  # Raised by the `raise_in_test` failure policy. A soft mirror failure never
  # raises in production (that would defeat the whole point of a shadow
  # write) - this exists purely so test suites can assert "the mirror did NOT
  # silently swallow a failure" without inspecting result hashes by hand.
  class MirrorFailure < StandardError
    attr_reader :result

    def initialize(message, result: nil)
      super(message)
      @result = result
    end
  end

  # Applies `Config#failure_policy` to a soft result hash returned by
  # `Mirror.mirror!` (or any client call with the same `{ ok:, status:,
  # committed:, retryable:, response:, error: }` shape). Never changes the
  # result itself - callers still get the original soft result back either
  # way; this only decides whether to ALSO warn or raise.
  module FailurePolicy
    module_function

    # `context` is free-form and only used to make a `warn`/raise message
    # actionable (e.g. `{ store: "orders", event_type: "order.accepted" }}`).
    def apply(result, policy: ActsAsTbackend.config.failure_policy, context: {})
      return result if success?(result)

      case policy
      when "warn"
        warn(describe(result, context))
      when "raise_in_test"
        raise MirrorFailure.new(describe(result, context), result: result) if test_env?
      when "ignore", "enqueue_retry"
        # `enqueue_retry` is reserved/status-only in P4 - no outbox worker
        # exists yet, so it is intentionally a no-op here, same as `ignore`.
      end

      result
    end

    # A soft result counts as a "failure" for policy purposes whenever it is
    # not an unambiguous success. `disabled` (the mirror kill-switch) and the
    # two write-ok statuses are the only successes; everything else (down
    # transport, circuit open, rejected, conflict, generic error) triggers
    # the configured policy.
    def success?(result)
      return true if result[:status] == "disabled"

      result[:ok] == true
    end

    def test_env?
      ENV["RAILS_ENV"] == "test" || ENV["RACK_ENV"] == "test" || ENV["TBACKEND_FORCE_TEST_MODE"] == "1"
    end

    def describe(result, context)
      ctx = context.empty? ? "" : " (#{context.map { |k, v| "#{k}=#{v}" }.join(', ')})"
      "[ActsAsTbackend] mirror failure#{ctx}: status=#{result[:status]} error=#{result[:error].inspect}"
    end
  end
end
