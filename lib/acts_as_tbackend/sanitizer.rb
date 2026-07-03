# frozen_string_literal: true

module ActsAsTbackend
  # Plain-Ruby attribute filter, used by Mirror to build a fact's `value`.
  # Framework-agnostic (no ActiveSupport) so it is unit-testable standalone.
  #
  #   Sanitizer.call({ "status" => "ok", "token" => "x" }, except: [:token])
  #   # => { "status" => "ok" }
  #
  # `only`/`except` are mutually exclusive selection of which attributes to
  # keep (matches the existing Mirror behavior exactly - see
  # `select_value_test.rb` / `mirror_test.rb`). `denylist` is applied
  # AFTERWARDS regardless of `only`/`except`, so a caller cannot accidentally
  # `only:` a secret field back in.
  module Sanitizer
    # Not applied unless a caller passes `denylist:` explicitly (or `true` for
    # this default set) - existing callers that pass neither keep their exact
    # current behavior. See the module doc comment.
    DEFAULT_DENYLIST = %w[
      password password_confirmation encrypted_password
      token access_token api_key secret secret_key
    ].freeze

    module_function

    def call(attributes, only: nil, except: nil, denylist: nil)
      attrs = stringify(attributes)
      attrs = select(attrs, only: only, except: except)
      deny(attrs, denylist: denylist)
    end

    def select(attrs, only:, except:)
      if only
        attrs.slice(*Array(only).map(&:to_s))
      elsif except
        attrs.except(*Array(except).map(&:to_s))
      else
        attrs
      end
    end

    # `denylist: true` opts into DEFAULT_DENYLIST; `denylist: [...]` uses a
    # custom list instead; `denylist: nil` (the default) applies no denylist
    # at all - only/except behavior is unchanged from before this module existed.
    def deny(attrs, denylist:)
      return attrs if denylist.nil? || denylist == false

      list = denylist == true ? DEFAULT_DENYLIST : Array(denylist).map(&:to_s)
      attrs.except(*list)
    end

    def stringify(hash)
      hash.each_with_object({}) { |(k, v), out| out[k.to_s] = v }
    end
  end
end
