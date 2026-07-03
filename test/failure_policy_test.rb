# frozen_string_literal: true

require_relative "test_helper"
require "acts_as_tbackend/test_helpers"

class FailurePolicyTest < Minitest::Test
  def failure_result
    { ok: false, status: "unavailable", committed: nil, retryable: true, response: nil, error: "boom" }
  end

  def success_result
    { ok: true, status: "committed_acked", committed: true, retryable: false, response: {}, error: nil }
  end

  def test_default_policy_is_ignore
    assert_equal "ignore", ActsAsTbackend::Config.new.failure_policy
  end

  def test_config_rejects_unknown_policy
    config = ActsAsTbackend::Config.new
    assert_raises(ArgumentError) { config.failure_policy = "explode" }
  end

  def test_ignore_does_nothing_and_returns_result_unchanged
    result = ActsAsTbackend::FailurePolicy.apply(failure_result, policy: "ignore")
    assert_equal failure_result, result
  end

  def test_success_never_triggers_the_policy
    out, = capture_io { ActsAsTbackend::FailurePolicy.apply(success_result, policy: "warn") }
    assert_empty out
  end

  def test_disabled_status_counts_as_success
    disabled = { ok: true, status: "disabled", committed: nil, retryable: false, response: nil, error: nil }
    out, = capture_io { ActsAsTbackend::FailurePolicy.apply(disabled, policy: "warn") }
    assert_empty out
  end

  def test_warn_policy_warns_on_failure
    _out, err = capture_io do
      ActsAsTbackend::FailurePolicy.apply(failure_result, policy: "warn", context: { store: "orders" })
    end

    assert_match(/mirror failure/, err)
    assert_match(/store=orders/, err)
    assert_match(/unavailable/, err)
  end

  def test_raise_in_test_raises_under_test_env
    ENV["TBACKEND_FORCE_TEST_MODE"] = "1"
    error = assert_raises(ActsAsTbackend::MirrorFailure) do
      ActsAsTbackend::FailurePolicy.apply(failure_result, policy: "raise_in_test")
    end
    assert_equal failure_result, error.result
  ensure
    ENV.delete("TBACKEND_FORCE_TEST_MODE")
  end

  def test_raise_in_test_does_not_raise_outside_test_env
    ENV.delete("TBACKEND_FORCE_TEST_MODE")
    ENV.delete("RAILS_ENV")
    ENV.delete("RACK_ENV")

    result = ActsAsTbackend::FailurePolicy.apply(failure_result, policy: "raise_in_test")
    assert_equal failure_result, result
  end

  def test_enqueue_retry_is_a_reserved_noop
    out, err = capture_io { ActsAsTbackend::FailurePolicy.apply(failure_result, policy: "enqueue_retry") }
    assert_empty out
    assert_empty err
  end

  def test_mirror_applies_the_configured_failure_policy
    ActsAsTbackend.config.failure_policy = "warn"
    record = FakeRecord.new(id: 1, updated_at: Time.at(100), attributes: {})

    ActsAsTbackend::TestHelpers.stub_client do |fake|
      fake.queue_result(status: :unavailable)
      _out, err = capture_io do
        ActsAsTbackend::Mirror.mirror!(record: record, store: "orders", event_type: "create")
      end
      assert_match(/mirror failure/, err)
    end
  ensure
    ActsAsTbackend.config.failure_policy = "ignore"
  end
end
