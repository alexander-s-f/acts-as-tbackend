# frozen_string_literal: true

# LAB-ACTS-AS-TBACKEND-ADAPTER-DX-P4: opt-in test support, NOT required by the
# core entrypoint (mirrors `extension.rb`'s opt-in shape) — an app's test
# suite requires this explicitly:
#
#   require "acts_as_tbackend/test_helpers"
#
# Framework-agnostic: works with Minitest, RSpec, or a plain script. Assertion
# failures raise ActsAsTbackend::TestHelpers::AssertionFailed (a plain
# StandardError), not a Minitest/RSpec-specific class, so this has no test
# framework as a runtime dependency.
require_relative "../acts_as_tbackend"

module ActsAsTbackend
  module TestHelpers
    class AssertionFailed < StandardError; end

    # A fake Client with the SAME public interface as ActsAsTbackend::Client
    # (write_fact_once, write_fact_once_safe, latest_for, facts_for,
    # facts_by_seq, ping, shutdown), returning queued canned soft-result
    # hashes instead of touching a socket or a real daemon. Every call is
    # recorded in `#calls` for inspection.
    #
    #   fake = ActsAsTbackend::TestHelpers.fake_client
    #   fake.queue_result(status: :unavailable)
    #   fake.queue_result(status: :committed_acked, seq_id: 9)
    #   ActsAsTbackend::TestHelpers.stub_client(fake) do
    #     Order.new.mirror_tbackend(event_type: "create") # sees :unavailable
    #     Order.new.mirror_tbackend(event_type: "create") # sees :committed_acked
    #   end
    class FakeClient
      CALLED_METHODS = %i[write_fact_once write_fact_once_safe latest_for facts_for facts_by_seq ping].freeze

      # Sensible ok/committed/retryable defaults per status, matching the
      # real Connection's response mapping (see connection.rb) — a caller
      # only needs to name the status; anything else can be overridden.
      STATUS_DEFAULTS = {
        "committed_acked" => { ok: true, committed: true, retryable: false },
        "idempotent_replay" => { ok: true, committed: true, retryable: false },
        "duplicate_fact_id_conflict" => { ok: false, committed: false, retryable: false },
        "rejected_before_commit" => { ok: false, committed: false, retryable: true },
        "unavailable" => { ok: false, committed: nil, retryable: true },
        "timeout_unknown" => { ok: false, committed: nil, retryable: nil },
        "circuit_open" => { ok: false, committed: nil, retryable: true },
        "ok" => { ok: true, committed: nil, retryable: false },
        "disabled" => { ok: true, committed: nil, retryable: false }
      }.freeze

      Call = Struct.new(:method, :args, :kwargs)

      def initialize
        @queue = []
        @calls = []
      end

      # Queue one canned result. `status:` may be any of STATUS_DEFAULTS's
      # keys or an arbitrary custom string; `**overrides` wins over the
      # default (e.g. `queue_result(status: :committed_acked, seq_id: 7)`).
      def queue_result(status:, response: nil, error: nil, **overrides)
        base = STATUS_DEFAULTS.fetch(status.to_s) { { ok: false, committed: nil, retryable: nil } }
        @queue << { status: status.to_s, response: response, error: error }.merge(base).merge(overrides)
        self
      end

      CALLED_METHODS.each do |name|
        define_method(name) do |*args, **kwargs|
          @calls << Call.new(name, args, kwargs)
          @queue.shift || default_result
        end
      end

      def shutdown; end

      # Every call made through this fake, in order — `calls.last.method`,
      # `calls.last.kwargs`, etc.
      def calls
        @calls
      end

      # How many canned results remain unconsumed (a test can assert a batch
      # was fully drained, or intentionally leave some queued).
      def remaining
        @queue.length
      end

      private

      def default_result
        { ok: true, status: "ok", committed: nil, retryable: false, response: nil, error: nil }
      end
    end

    module_function

    def fake_client
      FakeClient.new
    end

    # Swaps the process-wide `ActsAsTbackend.client` for `client` (default: a
    # fresh FakeClient) for the duration of the block, then restores whatever
    # was there before — including a real client if one was already memoized,
    # so this is safe to nest/call repeatedly across a test suite.
    def stub_client(client = fake_client)
      original = ActsAsTbackend.instance_variable_get(:@client)
      ActsAsTbackend.instance_variable_set(:@client, client)
      yield client
    ensure
      ActsAsTbackend.instance_variable_set(:@client, original)
    end

    # Asserts a built fact (the Hash returned by Mirror.build_fact /
    # Model#tbackend_fact) has the expected store/key and that `value`
    # contains (at least) the given key/value pairs. Raises AssertionFailed
    # with a readable message on mismatch; returns `true` on success so it
    # can also be used as a plain boolean check.
    def assert_tbackend_fact(fact, store: nil, key: nil, value_includes: nil)
      errors = []
      errors << "expected store #{store.inspect}, got #{fact['store'].inspect}" if store && fact["store"].to_s != store.to_s
      errors << "expected key #{key.inspect}, got #{fact['key'].inspect}" if key && fact["key"].to_s != key.to_s
      if value_includes
        value = fact["value"] || {}
        value_includes.each do |k, v|
          actual = value[k.to_s]
          errors << "expected value[#{k.inspect}] to be #{v.inspect}, got #{actual.inspect}" unless actual == v
        end
      end
      raise AssertionFailed, errors.join("; ") unless errors.empty?

      true
    end

    # Builds the fact `Mirror.mirror!` would build AND runs it through
    # `write_fact_once_safe` on the CURRENT `ActsAsTbackend.client` (real or
    # stubbed — combine with `stub_client` to avoid a live daemon), returning
    # both for inspection without needing a real record's after_commit hook.
    #
    #   ActsAsTbackend::TestHelpers.stub_client do |fake|
    #     fake.queue_result(status: :committed_acked)
    #     captured = ActsAsTbackend::TestHelpers.capture_mirror_result(
    #       record: order, store: "orders", event_type: "order.accepted"
    #     )
    #     assert_equal "committed_acked", captured[:result][:status]
    #   end
    def capture_mirror_result(record:, store:, event_type:, **opts)
      fact = ActsAsTbackend::Mirror.build_fact(record: record, store: store, event_type: event_type, **opts)
      result = ActsAsTbackend.client.write_fact_once_safe(fact)
      { fact: fact, result: result }
    end
  end
end
