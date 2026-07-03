# frozen_string_literal: true

require_relative "test_helper"
require "acts_as_tbackend/test_helpers"

class TestHelpersTest < Minitest::Test
  STATUSES_TO_STUB = %w[committed_acked idempotent_replay duplicate_fact_id_conflict
                        unavailable timeout_unknown circuit_open].freeze

  def test_fake_client_can_stub_every_required_status
    STATUSES_TO_STUB.each do |status|
      fake = ActsAsTbackend::TestHelpers.fake_client
      fake.queue_result(status: status)

      result = fake.ping

      assert_equal status, result[:status], "expected #{status} to be stubbable"
    end
  end

  def test_fake_client_serves_queued_results_in_order
    fake = ActsAsTbackend::TestHelpers.fake_client
    fake.queue_result(status: :unavailable)
    fake.queue_result(status: :committed_acked, seq_id: 9)

    first = fake.ping
    second = fake.write_fact_once({ "id" => "x" })

    assert_equal "unavailable", first[:status]
    assert_equal "committed_acked", second[:status]
    assert_equal 9, second[:seq_id]
  end

  def test_fake_client_falls_back_to_ok_when_queue_is_empty
    fake = ActsAsTbackend::TestHelpers.fake_client
    result = fake.ping
    assert_equal "ok", result[:status]
    assert result[:ok]
  end

  def test_fake_client_records_calls
    fake = ActsAsTbackend::TestHelpers.fake_client
    fake.queue_result(status: :ok)
    fake.latest_for(store: "orders", key: "order:1")

    call = fake.calls.last
    assert_equal :latest_for, call.method
    assert_equal({ store: "orders", key: "order:1" }, call.kwargs)
  end

  def test_stub_client_swaps_and_restores_the_module_client
    original = ActsAsTbackend.instance_variable_get(:@client)

    ActsAsTbackend::TestHelpers.stub_client do |fake|
      assert_same fake, ActsAsTbackend.client
      assert_kind_of ActsAsTbackend::TestHelpers::FakeClient, ActsAsTbackend.client
    end

    restored = ActsAsTbackend.instance_variable_get(:@client)
    if original.nil?
      assert_nil restored
    else
      assert_same original, restored
    end
  end

  def test_assert_tbackend_fact_passes_on_match
    fact = { "store" => "orders", "key" => "orders:1", "value" => { "status" => "ok", "n" => 1 } }
    assert ActsAsTbackend::TestHelpers.assert_tbackend_fact(
      fact, store: "orders", key: "orders:1", value_includes: { status: "ok" }
    )
  end

  def test_assert_tbackend_fact_raises_with_a_readable_message_on_mismatch
    fact = { "store" => "orders", "key" => "orders:1", "value" => { "status" => "ok" } }
    error = assert_raises(ActsAsTbackend::TestHelpers::AssertionFailed) do
      ActsAsTbackend::TestHelpers.assert_tbackend_fact(fact, store: "invoices")
    end
    assert_match(/expected store "invoices"/, error.message)
  end

  def test_capture_mirror_result_builds_and_writes_via_the_current_client
    record = FakeRecord.new(id: 5, updated_at: Time.at(100), attributes: { "status" => "ok" })

    ActsAsTbackend::TestHelpers.stub_client do |fake|
      fake.queue_result(status: :committed_acked, seq_id: 3)

      captured = ActsAsTbackend::TestHelpers.capture_mirror_result(
        record: record, store: "orders", event_type: "order.accepted"
      )

      ActsAsTbackend::TestHelpers.assert_tbackend_fact(
        captured[:fact], store: "orders", key: "orders:5", value_includes: { status: "ok" }
      )
      assert_equal "committed_acked", captured[:result][:status]
      assert_equal 3, captured[:result][:seq_id]
      assert_equal :write_fact_once_safe, fake.calls.last.method
    end
  end
end
