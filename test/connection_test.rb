# frozen_string_literal: true

require_relative "test_helper"

class ConnectionTest < Minitest::Test
  def test_ping_against_closed_port_is_unavailable_and_does_not_raise
    conn = ActsAsTbackend::Connection.new(host: "127.0.0.1", port: TestSupport.closed_port, connect_timeout: 0.5)
    result = conn.ping

    assert_equal "unavailable", result[:status]
    refute result[:ok]
  end

  def test_write_fact_once_maps_committed_acked
    conn = TestSupport.connection_with_response(
      { ok: true, committed: true, idempotent_replay: false, durability: "accepted", seq_id: 7 }
    )
    result = conn.write_fact_once({ "id" => "s:1:e:1", "store" => "s", "key" => "s:1", "value" => {} })

    assert_equal "committed_acked", result[:status]
    assert result[:ok]
    assert result[:committed]
  end

  def test_write_fact_once_maps_idempotent_replay
    conn = TestSupport.connection_with_response({ ok: true, committed: true, idempotent_replay: true, seq_id: 7 })
    result = conn.write_fact_once({ "id" => "s:1:e:1" })

    assert_equal "idempotent_replay", result[:status]
    assert result[:ok]
  end

  def test_write_fact_once_maps_duplicate_conflict
    conn = TestSupport.connection_with_response(
      { ok: false, committed: false, error_code: "duplicate_fact_id_conflict", error: "different content for id" }
    )
    result = conn.write_fact_once({ "id" => "s:1:e:1" })

    assert_equal "duplicate_fact_id_conflict", result[:status]
    refute result[:ok]
    refute result[:retryable]
  end

  def test_write_fact_once_maps_overloaded_to_rejected_before_commit
    conn = TestSupport.connection_with_response({ ok: false, committed: false, error_code: "overloaded", error: "busy" })
    result = conn.write_fact_once({ "id" => "s:1:e:1" })

    assert_equal "rejected_before_commit", result[:status]
    assert result[:retryable]
  end
end
