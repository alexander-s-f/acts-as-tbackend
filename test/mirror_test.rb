# frozen_string_literal: true

require_relative "test_helper"

class MirrorTest < Minitest::Test
  def test_build_fact_is_deterministic_and_filters_value
    record = FakeRecord.new(id: 42, updated_at: Time.at(1_780_387_174.5),
                            attributes: { "status" => "accepted", "secret" => "x" })

    a = ActsAsTbackend::Mirror.build_fact(record: record, store: "orders", event_type: "order.accepted", except: [:secret])
    b = ActsAsTbackend::Mirror.build_fact(record: record, store: "orders", event_type: "order.accepted", except: [:secret])

    assert_equal a["id"], b["id"]
    assert_equal "orders:42:order.accepted:1780387174500000", a["id"]
    assert_equal "orders:42", a["key"]
    assert_equal({ "status" => "accepted" }, a["value"]) # secret filtered out
    assert_equal "orders:42:order.accepted", a["causation"]
    refute a.key?("value_hash")
  end

  def test_only_filter_keeps_listed_attributes
    record = FakeRecord.new(id: 1, updated_at: Time.at(100), attributes: { "a" => 1, "b" => 2 })
    fact = ActsAsTbackend::Mirror.build_fact(record: record, store: "s", event_type: "update", only: [:a])

    assert_equal({ "a" => 1 }, fact["value"])
  end

  def test_tombstone_value
    record = FakeRecord.new(id: 1, updated_at: Time.at(100), attributes: {})
    fact = ActsAsTbackend::Mirror.build_fact(record: record, store: "s", event_type: "destroy", tombstone: true)

    assert_equal({ "_tombstone" => true }, fact["value"])
  end

  def test_mirror_is_a_soft_noop_when_disabled
    ActsAsTbackend.config.enabled = false
    record = FakeRecord.new(id: 1, updated_at: Time.at(100), attributes: {})

    result = ActsAsTbackend::Mirror.mirror!(record: record, store: "s", event_type: "create")

    assert_equal "disabled", result[:status]
    assert result[:ok]
  ensure
    ActsAsTbackend.config.enabled = true
  end
end
