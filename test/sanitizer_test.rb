# frozen_string_literal: true

require_relative "test_helper"

class SanitizerTest < Minitest::Test
  def test_no_filter_returns_stringified_attributes
    out = ActsAsTbackend::Sanitizer.call({ a: 1, "b" => 2 })
    assert_equal({ "a" => 1, "b" => 2 }, out)
  end

  def test_only_keeps_listed_attributes
    out = ActsAsTbackend::Sanitizer.call({ "a" => 1, "b" => 2, "c" => 3 }, only: [:a, "c"])
    assert_equal({ "a" => 1, "c" => 3 }, out)
  end

  def test_except_drops_listed_attributes
    out = ActsAsTbackend::Sanitizer.call({ "a" => 1, "b" => 2, "c" => 3 }, except: [:b])
    assert_equal({ "a" => 1, "c" => 3 }, out)
  end

  def test_only_and_except_together_only_wins_matching_mirror_precedent
    out = ActsAsTbackend::Sanitizer.call({ "a" => 1, "b" => 2 }, only: [:a], except: [:a])
    assert_equal({ "a" => 1 }, out)
  end

  def test_denylist_nil_by_default_preserves_existing_behavior
    out = ActsAsTbackend::Sanitizer.call({ "a" => 1, "password" => "x" })
    assert_equal({ "a" => 1, "password" => "x" }, out, "no denylist unless explicitly requested")
  end

  def test_denylist_true_applies_the_default_list
    out = ActsAsTbackend::Sanitizer.call(
      { "a" => 1, "password" => "x", "token" => "y", "api_key" => "z" }, denylist: true
    )
    assert_equal({ "a" => 1 }, out)
  end

  def test_denylist_custom_list
    out = ActsAsTbackend::Sanitizer.call({ "a" => 1, "ssn" => "123" }, denylist: [:ssn])
    assert_equal({ "a" => 1 }, out)
  end

  def test_denylist_applies_after_only_so_it_cannot_be_bypassed
    out = ActsAsTbackend::Sanitizer.call({ "a" => 1, "password" => "x" }, only: %i[a password], denylist: true)
    assert_equal({ "a" => 1 }, out, "a denylisted field must not survive even if `only` names it")
  end
end
