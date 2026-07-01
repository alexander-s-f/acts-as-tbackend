#!/usr/bin/env ruby
# frozen_string_literal: true

# Spark-shaped proof: sanitized lead_signals -> TBackend facts -> storage growth ->
# analytics/query -> safe manual compaction/rollup -> reboot. Ingest uses the
# acts-as-tbackend connector; analytics/snapshot/size use a small raw framed helper
# (ops the connector does not expose). Local, read-only Spark, temp daemon, auto-clean.
#
#   ruby -Ilib scripts/spark_outbox_leadsignal_probe.rb --sample 5000 [--scale 50000] [--json]

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "acts_as_tbackend"
require "optparse"
require "json"
require "socket"
require "zlib"
require "tmpdir"
require "fileutils"
require "timeout"

SPARKCRM = "/Users/alex/dev/projects/sparkcrm"
# NB: store names must NOT contain "." — the daemon rejects dotted store names on
# write_fact_once (the "." is the analytics value-path separator / WAL filename token).
# Use underscores. (Documented as a finding in the proof packet.)
STORE = "spark_lead_signals"
SUMMARY = "spark_lead_signals_summary"
COLD_STORE = "spark_lead_signals_cw"

o = { sample: 5000, scale: 50_000, sparkcrm: SPARKCRM, sample_file: nil, json: false, threads: 8 }
OptionParser.new do |p|
  p.on("--sample N", Integer) { |v| o[:sample] = v }
  p.on("--scale N", Integer) { |v| o[:scale] = v }
  p.on("--sparkcrm PATH") { |v| o[:sparkcrm] = v }
  p.on("--sample-file F") { |v| o[:sample_file] = v }
  p.on("--threads N", Integer) { |v| o[:threads] = v }
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

def dir_bytes(dir)
  Dir.glob(File.join(dir, "**", "*")).select { |f| File.file?(f) }.sum { |f| File.size(f) }
end

# ---- 1. obtain sanitized sample ----
sample_path = o[:sample_file]
unless sample_path
  sample_path = File.join(Dir.tmpdir, "spark_sample_#{o[:sample]}.json")
  export = File.expand_path("spark_export_sample.rb", __dir__)
  export_log = "#{sample_path}.log"
  # Redirect the Rails runner's own stdout/stderr to a log so it never pollutes the
  # probe's stdout (which is the JSON report). The sanitized sample goes to a file.
  cmd = %(cd #{o[:sparkcrm]} && DATABASE=spark_dev_db_2026_06_25 ANALYTICS_DATABASE=spark_dev_analytics_db_15_05_2026_v2 ) +
        %(PGCONNECT_TIMEOUT=8 bundle exec rails runner #{export} #{o[:sample]} #{sample_path} > #{export_log} 2>&1)
  warn "[probe] exporting sanitized sample via rails runner ..."
  unless system(cmd)
    warn(File.read(export_log)[-800..] || "") if File.exist?(export_log)
    abort "sample export failed (Spark DB unreachable?)"
  end
  File.delete(export_log) if File.exist?(export_log) && ENV["KEEP_TBACKEND_LOAD_ARTIFACTS"] != "1"
end
data = JSON.parse(File.read(sample_path))
rows = data.fetch("lead_signals")
abort "empty lead_signals sample" if rows.empty?

# ---- 2. start local daemon (compaction-enabled) ----
binary = File.expand_path("../../../igniter-tbackend/target/release/tbackend", __dir__)
abort "tbackend binary not found: #{binary}" unless File.executable?(binary)
tmp = Dir.mktmpdir("tbackend-spark-")
data_dir = File.join(tmp, "data")
log = File.join(tmp, "daemon.log")
port = (s = TCPServer.new("127.0.0.1", 0); pt = s.addr[1]; s.close; pt)
host = "127.0.0.1"
pid = Process.spawn(binary, "--host", host, "--port", port.to_s, "--data-dir", data_dir,
                    "--durability", "accepted", "--enable-compaction", "true", out: log, err: log)

ActsAsTbackend.configure do |c|
  c.host = host; c.port = port; c.pool_size = o[:threads]
  c.durability_default = "accepted"; c.request_timeout = 5.0; c.strict = false
  c.breaker_threshold = 1_000_000
end

report = { sample_n: rows.length, totals: data["totals"], store: STORE, daemon: { port: port } }

begin
  deadline = mono + 20
  sleep 0.05 until ActsAsTbackend.client.ping[:status] == "ok" || mono > deadline
  abort "daemon did not ping\n#{File.read(log)}" unless ActsAsTbackend.client.ping[:status] == "ok"

  # fact builders --------------------------------------------------------------
  build = lambda do |store, id_seed, version_us, key_id, value, valid_epoch|
    ActsAsTbackend::Fact.build(
      id: "#{store}:#{id_seed}:#{version_us}", store: store, key: "lead_signal:#{key_id}",
      value: value, valid_time: valid_epoch ? Time.at(valid_epoch) : nil
    )
  end

  real_facts = rows.map do |r|
    build.call(STORE, r["id"], r["updated_at_us"], r["id"], r["value"], r["signal_at_epoch"])
  end

  bulk_write = lambda do |facts, threads|
    stat = Hash.new(0); mtx = Mutex.new; t0 = mono
    facts.each_slice([(facts.size / threads.to_f).ceil, 1].max).map do |slice|
      Thread.new do
        local = Hash.new(0)
        slice.each { |f| local[ActsAsTbackend.client.write_fact_once(f)[:status]] += 1 }
        mtx.synchronize { local.each { |k, v| stat[k] += v } }
      end
    end.each(&:join)
    { elapsed: mono - t0, statuses: stat }
  end

  # ---- 3. storage growth: real sample, then synthetic-scale ----
  measure = lambda do |label, count|
    m = raw_req(host, port, op: "analytics_metrics", store: STORE)[:stores][STORE.to_sym] || {}
    { label: label, ingested: count,
      total_facts: m[:total_facts], unique_keys: m[:unique_keys], store_size_bytes: m[:size_bytes],
      wal_bytes: (File.size(File.join(data_dir, "#{STORE}.wal")) rescue nil),
      data_dir_bytes: dir_bytes(data_dir) }
  end

  w1 = bulk_write.call(real_facts, o[:threads])
  report[:ingest_real] = w1.merge(rpm: (rows.length / w1[:elapsed] * 60).round, storage: measure.call("real", rows.length))

  # ---- 4. analytics ops + baseline parity (on the clean real sample, before synthetic scale) ----
  agg = lambda do |group_by, aggregates|
    res = raw_req(host, port, op: "analytics_aggregate", store: STORE, group_by: group_by, aggregates: aggregates)
    (res[:results] || []).each_with_object({}) { |g, h| h[g[:group_value].to_s] = g[:aggregates] }
  end

  by_vendor = agg.call("value.vendor_name", [{ field: "value.bid", op: "sum" }, { field: "", op: "count" }])
  by_state  = agg.call("value.state", [{ field: "", op: "count" }])
  by_channel = agg.call("value.channel", [{ field: "", op: "count" }])
  by_elig   = agg.call("value.eligibility_mode", [{ field: "", op: "count" }])
  slice_accepted = raw_req(host, port, op: "query_slice", store: STORE, filters: { accepted: true })
  report[:analytics] = {
    aggregate_by_vendor_top: by_vendor.transform_values { |a| a[:count_fact] }.max_by(5) { |_, v| v }.to_h,
    aggregate_by_state: by_state.transform_values { |a| a[:count_fact] },
    aggregate_by_channel: by_channel.transform_values { |a| a[:count_fact] },
    aggregate_by_eligibility_mode: by_elig.transform_values { |a| a[:count_fact] },
    query_slice_accepted_count: (slice_accepted[:facts] || []).length
  }

  # analytics_calculate on a busy key (best-effort — timeline-per-key oriented)
  busy_key = rows.first["id"]
  calc = raw_req(host, port, op: "analytics_calculate", store: STORE, key: "lead_signal:#{busy_key}",
                 field: "value.bid", calculation: "sma", window_size: 3)
  report[:analytics][:analytics_calculate_ok] = calc[:ok]

  # baseline parity vs same-sample AR/Ruby counts
  base = data["baseline"]
  tb_vendor = by_vendor.transform_values { |a| a[:count_fact].to_i }
  tb_state = by_state.transform_values { |a| a[:count_fact].to_i }
  report[:parity] = {
    vendor_matches_baseline: tb_vendor == base["count_by_vendor_name"].transform_values(&:to_i),
    state_matches_baseline: tb_state == base["count_by_state"].transform_values(&:to_i),
    baseline_count_by_state: base["count_by_state"], tbackend_count_by_state: tb_state
  }

  # ---- 4b. synthetic-scale ingest (storage growth) — AFTER analytics/parity so the real store stays clean ----
  if o[:scale] && o[:scale] > rows.length
    synth = (0...o[:scale]).map do |i|
      base = rows[i % rows.length]
      build.call(STORE, "synth-#{i}", 1, "synth-#{i}", base["value"], base["signal_at_epoch"])
    end
    w2 = bulk_write.call(synth, o[:threads])
    report[:ingest_synthetic] = w2.merge(ingested: o[:scale], rpm: (o[:scale] / w2[:elapsed] * 60).round,
                                         storage: measure.call("synthetic_scale", o[:scale]),
                                         avg_bytes_per_fact: (measure.call("x", 0)[:store_size_bytes].to_f / [1, (rows.length + o[:scale])].max).round(1))
  end

  # ---- 5. compaction / rollup on a cold/warm split (explicit tx-time via raw write_fact) ----
  # 5 cold facts (4 days old = beyond 3-day retention) + 5 warm (now), from real value shapes.
  cold_t = Time.now.to_f - 4 * 86_400
  warm_t = Time.now.to_f
  samples = rows.first(10).map { |r| r["value"] }
  10.times do |i|
    tt = i < 5 ? cold_t : warm_t
    raw_req(host, port, op: "write_fact", fact: {
      id: "#{COLD_STORE}:#{i < 5 ? 'cold' : 'warm'}-#{i}:1", store: COLD_STORE, key: "lead_signal:cw-#{i}",
      value: samples[i % samples.length], value_hash: "cw#{i}", transaction_time: tt, valid_time: tt, schema_version: 1
    })
  end
  wal_cold_before = (File.size(File.join(data_dir, "#{COLD_STORE}.wal")) rescue nil)
  size_before = raw_req(host, port, op: "size", store: COLD_STORE)[:size]
  policy = raw_req(host, port, op: "snapshot_policy_create", source_store: COLD_STORE, target_store: SUMMARY,
                   retention_period: 3 * 86_400.0, group_by: ["value.vendor_name", "value.state", "value.accepted"],
                   aggregates: [{ field: "value.bid", op: "sum" }, { field: "", op: "count" }], interval: "daily")
  trig = raw_req(host, port, op: "snapshot_trigger", policy_id: policy[:policy_id])
  report[:compaction] = {
    policy_id: policy[:policy_id], ok: trig[:ok], pruned_facts: trig[:pruned_facts],
    created_summaries: trig[:created_summaries],
    size_before: size_before, size_after: raw_req(host, port, op: "size", store: COLD_STORE)[:size],
    summary_size: raw_req(host, port, op: "size", store: SUMMARY)[:size],
    wal_before: wal_cold_before, wal_after: (File.size(File.join(data_dir, "#{COLD_STORE}.wal")) rescue nil)
  }

  # ---- 6. reboot-after-compaction correctness ----
  ActsAsTbackend.client.shutdown
  Process.kill("TERM", pid); Timeout.timeout(5) { Process.wait(pid) } rescue Process.kill("KILL", pid)
  pid = Process.spawn(binary, "--host", host, "--port", port.to_s, "--data-dir", data_dir,
                      "--durability", "accepted", "--enable-compaction", "true", out: log, err: log)
  ActsAsTbackend.reset!
  deadline = mono + 20
  sleep 0.05 until ActsAsTbackend.client.ping[:status] == "ok" || mono > deadline
  report[:reboot] = {
    cold_store_facts: raw_req(host, port, op: "size", store: COLD_STORE)[:size],
    summary_facts: raw_req(host, port, op: "size", store: SUMMARY)[:size],
    main_store_facts: raw_req(host, port, op: "size", store: STORE)[:size]
  }
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
  File.delete(sample_path) if sample_path && !o[:sample_file] && File.exist?(sample_path) && ENV["KEEP_TBACKEND_LOAD_ARTIFACTS"] != "1"
end

puts JSON.pretty_generate(report)
