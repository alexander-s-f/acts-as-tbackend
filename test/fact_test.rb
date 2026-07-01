# frozen_string_literal: true

require_relative "test_helper"

class FactTest < Minitest::Test
  def test_derive_id_is_deterministic_and_colon_safe_for_time
    t = Time.at(1_780_387_174.5)
    a = ActsAsTbackend::Fact.derive_id(store: "orders", record_id: 42, event_type: "order.accepted", source_version: t)
    b = ActsAsTbackend::Fact.derive_id(store: "orders", record_id: 42, event_type: "order.accepted", source_version: t)

    assert_equal a, b
    assert_equal "orders:42:order.accepted:1780387174500000", a
    # exactly the three field separators; the version token carries no ":"
    assert_equal 3, a.count(":")
    assert_match(/\A\d+\z/, a.split(":").last)
  end

  def test_build_has_required_fields_and_omits_value_hash
    fact = ActsAsTbackend::Fact.build(id: "s:1:e:1", store: "s", key: "s:1", value: { "a" => 1 },
                                      valid_time: Time.at(100))

    assert_equal %w[id key schema_version store transaction_time valid_time value], fact.keys.sort
    assert_equal "s:1:e:1", fact["id"]
    assert_equal "s", fact["store"]
    assert_equal 100.0, fact["valid_time"]
    assert_kind_of Float, fact["transaction_time"]
    refute fact.key?("value_hash")
  end
end
