#!/usr/bin/env ruby
# frozen_string_literal: true

# Synthetic Rails lifecycle mirror proof: a real ActiveRecord model (SQLite in-memory)
# using the acts-as-tbackend extension, mirrored to a live local loopback tbackend.
# Proves create/update history, idempotent replay, daemon-down non-fatality, and
# aggregate/latest parity vs the AR baseline. Synthetic data only — no SparkCRM, no PII.
#
#   ruby -Ilib scripts/synthetic_rails_mirror_proof.rb [--records 60] [--json]

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "active_record"
require "acts_as_tbackend"
require "acts_as_tbackend/extension" # self-installs the macro into ActiveRecord::Base
require "socket"
require "json"
require "zlib"
require "tmpdir"
require "fileutils"
require "timeout"
require "optparse"

STORE = "spark_lead_signals"
o = { records: 60, json: false }
OptionParser.new do |p|
  p.on("--records N", Integer) { |v| o[:records] = v }
  p.on("--json") { o[:json] = true }
end.parse!(ARGV)

def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)

def raw_req(host, port, req)
  s = TCPSocket.new(host, port)
  s.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, true)
  body = JSON.generate(req).b
  s.write([body.bytesize].pack("N") + body + [Zlib.crc32(body)].pack("N"))
  len = s.read(4).unpack1("N")
  resp = s.read(len)
  s.read(4)
  JSON.parse(resp, symbolize_names: true)
ensure
  s&.close
end

report = { store: STORE, records: o[:records], checks: {} }
def check(report, name, cond, detail = nil)
  report[:checks][name] = { pass: !!cond, detail: detail }
  warn("  #{cond ? 'PASS' : 'FAIL'}: #{name}#{detail ? " (#{detail})" : ''}")
end

# ---- local daemon ----
binary = File.expand_path("../../../igniter-tbackend/target/release/tbackend", __dir__)
abort "tbackend binary not found: #{binary}" unless File.executable?(binary)
tmp = Dir.mktmpdir("tbackend-synth-")
data_dir = File.join(tmp, "data")
log = File.join(tmp, "daemon.log")
host = "127.0.0.1"
port = (srv = TCPServer.new(host, 0); pt = srv.addr[1]; srv.close; pt)
pid = Process.spawn(binary, "--host", host, "--port", port.to_s, "--data-dir", data_dir,
                    "--durability", "accepted", out: log, err: log)

ActsAsTbackend.configure do |c|
  c.host = host; c.port = port; c.pool_size = 4
  c.durability_default = "accepted"; c.request_timeout = 3.0; c.connect_timeout = 1.0; c.strict = false
end

begin
  deadline = mono + 20
  sleep 0.05 until ActsAsTbackend.client.ping[:status] == "ok" || mono > deadline
  abort "daemon did not ping\n#{File.read(log)}" unless ActsAsTbackend.client.ping[:status] == "ok"

  # ---- synthetic AR model (SQLite in-memory) ----
  ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
  ActiveRecord::Schema.verbose = false
  ActiveRecord::Schema.define do
    create_table :synthetic_lead_signals do |t|
      t.string :channel; t.string :vendor_name; t.string :state
      t.boolean :accepted, default: false
      t.float :bid, default: 0.0
      t.boolean :converted, default: false
      t.string :order_status; t.string :eligibility_mode
      t.datetime :signal_at
      t.timestamps
    end
  end

  synthetic_model = Class.new(ActiveRecord::Base) do
    self.table_name = "synthetic_lead_signals"
    acts_as_tbackend store: STORE,
                     only: %i[channel vendor_name state accepted bid converted order_status eligibility_mode]
    before_save { self.valid_time = signal_at }
  end
  Object.const_set(:SyntheticLeadSignal, synthetic_model)

  vendors = %w[eLocal inquirly apexlocal]
  states = %w[FL TX NY OH]

  # ---- (a) create: each AR create mirrors one fact via after_commit ----
  created = o[:records].times.map do |i|
    SyntheticLeadSignal.create!(
      channel: "webhook", vendor_name: vendors[i % vendors.size], state: states[i % states.size],
      accepted: i.even?, bid: (10.0 + (i % 7)), converted: (i % 5).zero?, order_status: "new",
      eligibility_mode: nil, signal_at: Time.now - i * 60
    )
  end
  sleep 0.2
  total = raw_req(host, port, op: "size", store: STORE)[:size]
  check(report, "create_mirrors_one_fact_per_record", total == o[:records], "size=#{total} records=#{o[:records]}")

  # observable status: explicit mirror of an already-committed record -> idempotent_replay
  rep = created.first.mirror_tbackend(event_type: "create")
  check(report, "create_status_committed_or_replay", %w[committed_acked idempotent_replay].include?(rep[:status]), rep[:status])

  # ---- (e) aggregate parity vs AR baseline (measured before any update adds versions) ----
  ar_by_vendor = SyntheticLeadSignal.group(:vendor_name).count
  agg = raw_req(host, port, op: "analytics_aggregate", store: STORE, group_by: "value.vendor_name",
                aggregates: [{ field: "", op: "count" }])[:results] || []
  tb_by_vendor = agg.each_with_object({}) { |g, h| h[g[:group_value]] = g[:aggregates][:count_fact].to_i }
  check(report, "aggregate_parity_vendor", tb_by_vendor == ar_by_vendor,
        "ar=#{ar_by_vendor} tb=#{tb_by_vendor}")

  # ---- (b) update: second version under the same key; history shows both ----
  rec = created.first
  rec.update!(bid: 999.99, order_status: "updated")
  sleep 0.15
  # NB: the Mirror builds key = "#{store}:#{record_id}" (not "lead_signal:<id>" as the card suggested).
  key = "#{STORE}:#{rec.id}"
  hist = raw_req(host, port, op: "facts_for", store: STORE, key: key)[:facts] || []
  check(report, "update_history_two_versions", hist.size == 2, "facts_for(#{key})=#{hist.size}")

  # ---- (f) latest query matches newest AR value ----
  latest = raw_req(host, port, op: "latest_for", store: STORE, key: key)[:fact]
  check(report, "latest_matches_ar", latest && latest[:value][:bid].to_f == rec.reload.bid,
        "tb=#{latest && latest[:value][:bid]} ar=#{rec.bid}")

  # ---- (d) idempotency: re-mirror same record -> replay, no new fact ----
  before = raw_req(host, port, op: "facts_for", store: STORE, key: key)[:facts].size
  r1 = rec.mirror_tbackend(event_type: "update")
  r2 = rec.mirror_tbackend(event_type: "update")
  after = raw_req(host, port, op: "facts_for", store: STORE, key: key)[:facts].size
  check(report, "idempotent_replay_no_dup", r2[:status] == "idempotent_replay" && before == after,
        "r1=#{r1[:status]} r2=#{r2[:status]} facts #{before}->#{after}")

  # ---- (c) daemon-down: AR write still succeeds; mirror soft/classified ----
  ActsAsTbackend.client.shutdown
  Process.kill("TERM", pid); Timeout.timeout(5) { Process.wait(pid) } rescue Process.kill("KILL", pid)
  pid = nil
  ActsAsTbackend.reset!
  down_rec = nil
  ar_ok = begin
    down_rec = SyntheticLeadSignal.create!(channel: "webhook", vendor_name: "eLocal", state: "FL",
                                           accepted: true, bid: 5.0, signal_at: Time.now)
    SyntheticLeadSignal.exists?(down_rec.id)
  rescue StandardError
    false
  end
  down_status = down_rec ? down_rec.mirror_tbackend(event_type: "create")[:status] : "no_record"
  check(report, "daemon_down_ar_write_survives", ar_ok, "record persisted=#{ar_ok}")
  check(report, "daemon_down_mirror_soft", %w[unavailable timeout_unknown circuit_open].include?(down_status), down_status)

  report[:ar_baseline_by_vendor] = ar_by_vendor
  report[:tbackend_by_vendor] = tb_by_vendor
rescue StandardError => e
  report[:error] = "#{e.class}: #{e.message}"
  report[:backtrace] = e.backtrace&.first(6)
ensure
  ActsAsTbackend.client.shutdown rescue nil
  if pid
    Process.kill("TERM", pid) rescue nil
    begin
      Timeout.timeout(5) { Process.wait(pid) }
    rescue StandardError
      Process.kill("KILL", pid) rescue nil
    end
  end
  FileUtils.remove_entry(tmp) if ENV["KEEP_TBACKEND_LOAD_ARTIFACTS"] != "1" && Dir.exist?(tmp)
end

report[:all_passed] = report[:checks].values.all? { |c| c[:pass] } && report[:error].nil?
if o[:json]
  puts JSON.pretty_generate(report)
else
  report[:checks].each { |k, c| puts "  #{c[:pass] ? 'PASS' : 'FAIL'}: #{k}#{c[:detail] ? " (#{c[:detail]})" : ''}" }
end
warn(report[:all_passed] ? "\nALL CHECKS PASSED" : "\nFAILED: #{report[:checks].reject { |_, c| c[:pass] }.keys} #{report[:error]}")
exit(report[:all_passed] ? 0 : 1)
