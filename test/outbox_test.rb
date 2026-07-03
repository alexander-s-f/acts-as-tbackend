# frozen_string_literal: true

require_relative "test_helper"
require "acts_as_tbackend/test_helpers"

class OutboxTest < Minitest::Test
  def record
    FakeRecord.new(id: 42, updated_at: Time.at(1_780_387_174.5),
                   attributes: { "status" => "accepted", "secret" => "x" })
  end

  def test_intent_from_record_preserves_deterministic_fact_id
    a = ActsAsTbackend::OutboxIntent.from_record(
      record: record, store: "orders", event_type: "order.accepted", except: [:secret]
    )
    b = ActsAsTbackend::OutboxIntent.from_record(
      record: record, store: "orders", event_type: "order.accepted", except: [:secret]
    )

    assert_equal "orders:42:order.accepted:1780387174500000", a.fact["id"]
    assert_equal a.fact["id"], a.id
    assert_equal a.id, b.id
    assert_equal({ "status" => "accepted" }, a.fact["value"])
  end

  def test_intent_serializes_and_deserializes_for_app_owned_storage
    intent = ActsAsTbackend::OutboxIntent.from_record(
      record: record, store: "orders", event_type: "order.accepted", except: [:secret]
    )

    restored = ActsAsTbackend::OutboxIntent.from_h(intent.to_h)

    assert_equal intent.id, restored.id
    assert_equal intent.fact, restored.fact
    assert_equal 0, restored.attempts
  end

  def test_intent_requires_a_complete_fact_envelope
    error = assert_raises(ArgumentError) do
      ActsAsTbackend::OutboxIntent.new(fact: { id: "x", store: "s", value: {} })
    end

    assert_match(/key/, error.message)
  end

  def test_flush_maps_inserted
    result = flush_with_status(:committed_acked)

    assert_equal "inserted", result[:status]
    assert result[:ok]
    assert result[:terminal]
    refute result[:retryable]
  end

  def test_flush_maps_replay
    result = flush_with_status(:idempotent_replay)

    assert_equal "replay", result[:status]
    assert result[:ok]
    assert result[:terminal]
    refute result[:retryable]
  end

  def test_flush_maps_conflict_as_terminal_non_retryable
    result = flush_with_status(:duplicate_fact_id_conflict)

    assert_equal "conflict", result[:status]
    refute result[:ok]
    assert result[:terminal]
    refute result[:retryable]
  end

  def test_flush_maps_unavailable_as_retryable
    result = flush_with_status(:unavailable)

    assert_equal "retryable", result[:status]
    refute result[:ok]
    refute result[:terminal]
    assert result[:retryable]
  end

  def test_flush_maps_timeout_unknown_without_inferring_commit
    result = flush_with_status(:timeout_unknown)

    assert_equal "unknown", result[:status]
    refute result[:ok]
    refute result[:terminal]
    assert result[:retryable]
  end

  def test_flush_records_attempt_status_and_uses_write_fact_once
    fake = ActsAsTbackend::TestHelpers.fake_client
    fake.queue_result(status: :committed_acked)
    intent = ActsAsTbackend::OutboxIntent.from_record(record: record, store: "orders", event_type: "create")

    result = ActsAsTbackend::OutboxFlusher.flush(intent, client: fake, durability: "durable", timeout: 0.5)

    assert_equal 1, result[:intent].attempts
    assert_equal "committed_acked", result[:intent].last_status
    assert_equal :write_fact_once, fake.calls.last.method
    assert_equal intent.fact, fake.calls.last.args.first
    assert_equal({ durability: "durable", timeout: 0.5 }, fake.calls.last.kwargs)
  end

  private

  def flush_with_status(status)
    fake = ActsAsTbackend::TestHelpers.fake_client
    fake.queue_result(status: status)
    intent = ActsAsTbackend::OutboxIntent.from_record(record: record, store: "orders", event_type: "create")

    ActsAsTbackend::OutboxFlusher.flush(intent, client: fake)
  end
end
