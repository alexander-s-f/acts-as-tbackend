# frozen_string_literal: true

require "active_support/concern"

module ActsAsTbackend
  module Extension
    extend ActiveSupport::Concern

    included do
      attr_accessor :valid_time
    end

    class_methods do
      def acts_as_tbackend(options = {})
        class_attribute :tbackend_options
        self.tbackend_options = {
          store: options[:store] || table_name,
          only: options[:only] ? Array(options[:only]).map(&:to_sym) : nil,
          except: options[:except] ? Array(options[:except]).map(&:to_sym) : nil,
          host: options[:host] || "127.0.0.1",
          port: options[:port] || 7401,
          async: options.key?(:async) ? !!options[:async] : true
        }

        # Wire up ActiveRecord lifecycle callbacks
        after_commit :commit_tbackend_fact, on: %i[create update]
        after_commit :commit_tbackend_destroy_fact, on: :destroy
      end

      # Class-level query API
      def tbackend_history(id)
        return [] unless ActsAsTbackend.enabled?
        begin
          opts = tbackend_options
          client = ActsAsTbackend.client(opts[:host], opts[:port])
          client.facts_for(store: opts[:store], key: id)
        rescue => e
          warn "[ActsAsTbackend] Error in tbackend_history: #{e.message}"
          []
        end
      end

      def tbackend_latest_for(id, as_of: nil)
        return nil unless ActsAsTbackend.enabled?
        begin
          opts = tbackend_options
          client = ActsAsTbackend.client(opts[:host], opts[:port])
          client.latest_for(store: opts[:store], key: id, as_of: as_of)
        rescue => e
          warn "[ActsAsTbackend] Error in tbackend_latest_for: #{e.message}"
          nil
        end
      end

      def tbackend_query_scope(filters = {}, as_of: nil)
        return [] unless ActsAsTbackend.enabled?
        begin
          opts = tbackend_options
          client = ActsAsTbackend.client(opts[:host], opts[:port])
          client.query_scope(store: opts[:store], filters: filters, as_of: as_of)
        rescue => e
          warn "[ActsAsTbackend] Error in tbackend_query_scope: #{e.message}"
          []
        end
      end
    end

    private

    def commit_tbackend_fact
      return unless ActsAsTbackend.enabled?

      opts = self.class.tbackend_options
      store = opts[:store].to_s
      key_id = self.id.to_s
      vt = self.valid_time

      attrs = self.attributes.symbolize_keys
      if opts[:only]
        attrs = attrs.slice(*opts[:only])
      elsif opts[:except]
        attrs = attrs.except(*opts[:except])
      end

      if opts[:async]
        job_args = {
          opts: { host: opts[:host], port: opts[:port] },
          fact: { store: store, key: key_id, value: attrs, valid_time: vt }
        }
        ActsAsTbackend.enqueue_job("write_fact", job_args)
      else
        begin
          client = ActsAsTbackend.client(opts[:host], opts[:port])
          prev_fact = client.latest_for(store: store, key: key_id) rescue nil
          causation = prev_fact ? prev_fact[:id] : nil

          client.write_fact(
            store: store,
            key: key_id,
            value: attrs,
            causation: causation,
            valid_time: vt
          )
        rescue => e
          if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
            Rails.logger.error("[ActsAsTbackend] Error committing fact to TBackend: #{e.message}")
          else
            warn "[ActsAsTbackend] Error committing fact: #{e.message}"
          end
        end
      end
    end

    def commit_tbackend_destroy_fact
      return unless ActsAsTbackend.enabled?

      opts = self.class.tbackend_options
      store = opts[:store].to_s
      key_id = self.id.to_s
      vt = self.valid_time

      if opts[:async]
        job_args = {
          opts: { host: opts[:host], port: opts[:port] },
          fact: { store: store, key: key_id, value: { _tombstone: true }, valid_time: vt }
        }
        ActsAsTbackend.enqueue_job("write_fact", job_args)
      else
        begin
          client = ActsAsTbackend.client(opts[:host], opts[:port])
          prev_fact = client.latest_for(store: store, key: key_id) rescue nil
          causation = prev_fact ? prev_fact[:id] : nil

          client.write_fact(
            store: store,
            key: key_id,
            value: { _tombstone: true },
            causation: causation,
            valid_time: vt
          )
        rescue => e
          if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
            Rails.logger.error("[ActsAsTbackend] Error committing tombstone to TBackend: #{e.message}")
          else
            warn "[ActsAsTbackend] Error committing tombstone: #{e.message}"
          end
        end
      end
    end
  end
end
