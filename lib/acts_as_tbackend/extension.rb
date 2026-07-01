# frozen_string_literal: true

require "active_support/concern"
require_relative "mirror"

module ActsAsTbackend
  # ActiveRecord integration for the refreshed core. `acts_as_tbackend` mirrors model
  # lifecycle to TBackend on after_commit — synchronously, with a soft/non-fatal
  # result (a down daemon never raises into the request path). For heavy write paths,
  # call `record.tbackend_fact(...)` from your own background job instead.
  #
  #   class Order < ApplicationRecord
  #     acts_as_tbackend store: "orders", except: %i[created_at updated_at]
  #   end
  module Extension
    extend ActiveSupport::Concern

    included do
      # Optional domain valid-time for the fact; defaults to nil.
      attr_accessor :valid_time unless method_defined?(:valid_time)
    end

    class_methods do
      def acts_as_tbackend(store: nil, only: nil, except: nil)
        class_attribute :tbackend_options
        self.tbackend_options = { store: (store || table_name).to_s, only: only, except: except }

        after_commit :mirror_tbackend_create_update, on: %i[create update]
        after_commit :mirror_tbackend_destroy, on: :destroy
      end

      # ---- class-level read API (routes through the shared pooled client) ----

      def tbackend_history(id)
        tbackend_guard([]) { ActsAsTbackend.client.facts_for(store: tbackend_options[:store], key: id.to_s) }
      end

      def tbackend_latest_for(id, as_of: nil)
        tbackend_guard(nil) { ActsAsTbackend.client.latest_for(store: tbackend_options[:store], key: id.to_s, as_of: as_of) }
      end

      def tbackend_facts_by_seq(after_seq: 0, until_seq: nil)
        tbackend_guard([]) do
          ActsAsTbackend.client.facts_by_seq(store: tbackend_options[:store], after_seq: after_seq, until_seq: until_seq)
        end
      end

      def tbackend_guard(default)
        return default unless ActsAsTbackend.enabled?

        yield
      rescue StandardError => e
        ActsAsTbackend::Extension.log("query error: #{e.message}")
        default
      end
    end

    # Public: build the fact for this record (no write) — for apps mirroring from
    # their own job.
    def tbackend_fact(event_type:, tombstone: false)
      opts = self.class.tbackend_options
      ActsAsTbackend::Mirror.build_fact(
        record: self, store: opts[:store], event_type: event_type,
        only: opts[:only], except: opts[:except], tombstone: tombstone, valid_time: valid_time
      )
    end

    def mirror_tbackend(event_type:, tombstone: false)
      opts = self.class.tbackend_options
      ActsAsTbackend::Mirror.mirror!(
        record: self, store: opts[:store], event_type: event_type,
        only: opts[:only], except: opts[:except], tombstone: tombstone, valid_time: valid_time
      )
    rescue StandardError => e
      ActsAsTbackend::Extension.log("mirror error: #{e.message}")
      { ok: false, status: "error", committed: nil, retryable: nil, response: nil, error: e.message }
    end

    def self.log(message)
      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger.error("[ActsAsTbackend] #{message}")
      else
        warn "[ActsAsTbackend] #{message}"
      end
    end

    private

    def mirror_tbackend_create_update
      event = respond_to?(:previously_new_record?) && previously_new_record? ? "create" : "update"
      mirror_tbackend(event_type: event)
    end

    def mirror_tbackend_destroy
      mirror_tbackend(event_type: "destroy", tombstone: true)
    end
  end
end

# Self-install the macro when ActiveRecord loads (opt-in: the core entry does not
# require this file, keeping `require "acts_as_tbackend"` ActiveRecord-free).
if defined?(ActiveSupport) && ActiveSupport.respond_to?(:on_load)
  ActiveSupport.on_load(:active_record) { include ActsAsTbackend::Extension }
end
