# frozen_string_literal: true

module ActsAsTbackend
  # Flushes a single OutboxIntent through an app-provided client.
  #
  # No persistence or retry loop lives here. The caller owns when to retry and
  # where to store attempts; this helper only preserves the deterministic fact id
  # and maps daemon/client soft results into outbox-friendly statuses.
  module OutboxFlusher
    module_function

    def flush(intent, client: ActsAsTbackend.client, durability: nil, timeout: nil)
      intent = OutboxIntent.from_h(intent) if intent.is_a?(Hash)
      result = client.write_fact_once(intent.fact, durability: durability, timeout: timeout)
      flush_result(intent: intent.record_result(result), result: result)
    end

    def flush_result(intent:, result:)
      status = outbox_status(result)
      {
        ok: outbox_ok?(status),
        status: status,
        terminal: terminal?(status),
        retryable: retryable?(status),
        intent: intent,
        result: result
      }
    end

    def outbox_status(result)
      case result[:status].to_s
      when "committed_acked" then "inserted"
      when "idempotent_replay" then "replay"
      when "duplicate_fact_id_conflict" then "conflict"
      when "timeout_unknown" then "unknown"
      when "unavailable", "circuit_open", "rejected_before_commit" then "retryable"
      else
        result[:retryable] ? "retryable" : "failed"
      end
    end

    def outbox_ok?(status)
      %w[inserted replay].include?(status)
    end

    def terminal?(status)
      %w[inserted replay conflict failed].include?(status)
    end

    def retryable?(status)
      %w[retryable unknown].include?(status)
    end
  end
end
