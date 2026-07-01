# frozen_string_literal: true

# Read-only, ALLOWLISTED export of a Spark lead_signals / outbox_events sample for
# the TBackend Spark-shaped proof. Run FROM sparkcrm via Rails runner:
#
#   cd /Users/alex/dev/projects/sparkcrm
#   DATABASE=spark_dev_db_2026_06_25 ANALYTICS_DATABASE=spark_dev_analytics_db_15_05_2026_v2 \
#     bundle exec rails runner <abs>/scripts/spark_export_sample.rb <N> <out.json>
#
# Writes sanitized JSON to <out.json>. NEVER emits raw did/upi/request_id/trace_id/
# phone/email/name/address or full payload/data — only allowlisted fields + has_* flags
# + *_keys. Read-only: no writes to SparkCRM.

require "json"

ActiveRecord::Base.logger = nil # keep stdout clean

n = (ARGV[0] || "5000").to_i
out = ARGV[1] || "spark_sample.json"

def us(t)
  return nil if t.nil?

  t.to_i * 1_000_000 + t.usec
end

# ---- lead_signals (analytics DB) ----
lead = LeadSignal.order(signal_at: :desc).limit(n).map do |ls|
  {
    "id" => ls.id,
    "updated_at_us" => us(ls.updated_at),
    "signal_at_epoch" => ls.signal_at&.to_f,
    "value" => {
      "channel" => ls.channel,
      "trade_name" => ls.trade_name,
      "vendor_name" => ls.vendor_name,
      "zip_code" => ls.zip_code,
      "city" => ls.city,
      "county" => ls.county,
      "state" => ls.state,
      "timezone" => ls.timezone,
      "accepted" => ls.accepted,
      "bid" => ls.bid&.to_f,
      "converted" => ls.converted,
      "order_status" => ls.order_status,
      "eligibility_mode" => ls.eligibility_mode,
      "eligibility_slots" => ls.eligibility_slots,
      "eligibility_threshold" => ls.eligibility_threshold&.to_f,
      "external_operator_id" => ls.external_operator_id,
      "external_trade_id" => ls.external_trade_id,
      "external_vendor_id" => ls.external_vendor_id,
      "linkage_source" => ls.linkage_source,
      "linkage_confidence" => ls.linkage_confidence&.to_f,
      "has_did" => ls.did.present?,
      "has_upi" => ls.upi.present?,
      "has_request_id" => ls.request_id.present?,
      "has_trace_id" => ls.trace_id.present?,
      "data_keys" => (ls.data.is_a?(Hash) ? ls.data.keys.map(&:to_s).sort : [])
    }
  }
end

# Same-sample baselines (computed in Ruby so TBackend aggregates compare apples-to-apples)
def count_by(rows, field)
  rows.each_with_object(Hash.new(0)) { |r, h| h[r["value"][field].to_s] += 1 }
end

vals = lead.map { |r| r["value"] }
baseline = {
  "count" => lead.length,
  "count_by_vendor_name" => count_by(lead, "vendor_name"),
  "count_by_state" => count_by(lead, "state"),
  "count_by_channel" => count_by(lead, "channel"),
  "accepted_true" => vals.count { |v| v["accepted"] },
  "converted_true" => vals.count { |v| v["converted"] },
  "sum_bid" => vals.sum { |v| v["bid"].to_f }.round(2)
}

shape = {
  "signal_at_range" => [lead.last&.dig("signal_at_epoch"), lead.first&.dig("signal_at_epoch")],
  "null_rates" => %w[trade_name vendor_name state eligibility_mode order_status].each_with_object({}) do |f, h|
    h[f] = vals.count { |v| v[f].nil? || v[f] == "" }
  end
}

report = {
  "generated_from" => { "lead_signals_db" => "spark_dev_analytics_db_15_05_2026_v2",
                        "outbox_db" => "spark_dev_db_2026_06_25" },
  "totals" => { "lead_signals" => LeadSignal.count, "outbox_events" => OutboxEvent.count },
  "sample_n" => n,
  "lead_signals" => lead,
  "outbox_events" => [], # OutboxEvent is empty in this dev DB (documented in the proof packet)
  "baseline" => baseline,
  "shape" => shape
}

File.write(out, JSON.generate(report))
puts "WROTE #{out} (lead_signals sample=#{lead.length}, outbox=0)"
