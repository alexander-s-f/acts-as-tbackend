#!/usr/bin/env ruby
# frozen_string_literal: true

# Local load proof for the acts-as-tbackend connector against a real loopback
# tbackend daemon. Drives writes through ActsAsTbackend::Client + Fact (not a bespoke
# socket client), records status mix + latency percentiles, and cleans up.
#
#   ruby -Ilib scripts/load_local_daemon.rb --writes 10000 --threads 8 --pool-size 8 \
#     --durability accepted --max-inflight 256 [--passes 2] [--json] [--label A]
#
# Set KEEP_TBACKEND_LOAD_ARTIFACTS=1 to keep the temp data-dir + daemon log.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "acts_as_tbackend"
require "optparse"
require "tmpdir"
require "fileutils"
require "socket"
require "timeout"
require "json"

STORE = "load_test"

o = { port: "auto", writes: 10_000, threads: 8, pool_size: 8, durability: "accepted",
      max_inflight: 256, passes: 1, version: 1_000_000, json: false, binary: nil, label: nil }
OptionParser.new do |p|
  p.on("--port PORT") { |v| o[:port] = v }
  p.on("--writes N", Integer) { |v| o[:writes] = v }
  p.on("--threads N", Integer) { |v| o[:threads] = v }
  p.on("--pool-size N", Integer) { |v| o[:pool_size] = v }
  p.on("--durability D") { |v| o[:durability] = v }
  p.on("--max-inflight N", Integer) { |v| o[:max_inflight] = v }
  p.on("--passes N", Integer) { |v| o[:passes] = v }
  p.on("--version N", Integer) { |v| o[:version] = v }
  p.on("--binary PATH") { |v| o[:binary] = v }
  p.on("--label L") { |v| o[:label] = v }
  p.on("--json") { o[:json] = true }
end.parse!(ARGV)

def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)

def free_port
  s = TCPServer.new("127.0.0.1", 0)
  port = s.addr[1]
  s.close
  port
end

def percentile(sorted, pct)
  return 0.0 if sorted.empty?

  rank = (pct / 100.0) * (sorted.length - 1)
  lo = sorted[rank.floor]
  hi = sorted[rank.ceil]
  lo + (hi - lo) * (rank - rank.floor)
end

binary = o[:binary] || File.expand_path("../../../igniter-tbackend/target/release/tbackend", __dir__)
abort "tbackend binary not found/executable: #{binary}" unless File.executable?(binary)

host = "127.0.0.1"
port = o[:port] == "auto" ? free_port : o[:port].to_i
tmp = Dir.mktmpdir("tbackend-load-")
log = File.join(tmp, "daemon.log")
pid = Process.spawn(
  binary, "--host", host, "--port", port.to_s, "--data-dir", File.join(tmp, "data"),
  "--durability", o[:durability], "--max-inflight-requests", o[:max_inflight].to_s,
  out: log, err: log
)

ActsAsTbackend.configure do |c|
  c.host = host
  c.port = port
  c.pool_size = o[:pool_size]
  c.durability_default = o[:durability]
  c.connect_timeout = 2.0
  c.request_timeout = 5.0
  c.strict = false
  c.breaker_threshold = 1_000_000 # do not let the breaker mask raw daemon statuses during the load
end

def wait_ping(deadline)
  loop do
    return true if ActsAsTbackend.client.ping[:status] == "ok"
    return false if mono > deadline

    sleep 0.05
  end
end

def run_pass(facts, threads)
  latencies = Array.new(threads) { [] }
  statuses = Array.new(threads) { Hash.new(0) }
  slices = facts.each_slice([(facts.size / threads.to_f).ceil, 1].max).to_a
  t0 = mono
  slices.each_with_index.map do |slice, ti|
    Thread.new do
      slice.each do |fact|
        s = mono
        r = ActsAsTbackend.client.write_fact_once_safe(fact)
        latencies[ti] << (mono - s)
        statuses[ti][r[:status]] += 1
      end
    end
  end.each(&:join)
  merged = statuses.each_with_object(Hash.new(0)) { |h, acc| h.each { |k, v| acc[k] += v } }
  { elapsed: mono - t0, latencies: latencies.flatten, statuses: merged }
end

def summarize(pass, writes)
  lat = pass[:latencies].sort
  ms = ->(sec) { (sec * 1000).round(3) }
  {
    writes: writes,
    elapsed_s: pass[:elapsed].round(3),
    writes_per_sec: (writes / pass[:elapsed]).round(1),
    rpm: (writes / pass[:elapsed] * 60).round,
    statuses: pass[:statuses],
    p50_ms: ms.call(percentile(lat, 50)),
    p95_ms: ms.call(percentile(lat, 95)),
    p99_ms: ms.call(percentile(lat, 99)),
    max_ms: ms.call(lat.last || 0)
  }
end

report = { label: o[:label], config: o.slice(:writes, :threads, :pool_size, :durability, :max_inflight, :passes),
           daemon: { pid: pid, host: host, port: port, data_dir: tmp } }

begin
  unless wait_ping(mono + 20)
    report[:error] = "daemon did not answer ping"
    report[:daemon_log_tail] = (File.readlines(log).last(20) rescue [])
    puts JSON.generate(report)
    exit 1
  end

  version_time = Time.at(o[:version]) # fixed -> deterministic ids (retry/pass = idempotent replay)
  facts = (0...o[:writes]).map do |i|
    id = ActsAsTbackend::Fact.derive_id(store: STORE, record_id: i, event_type: "load", source_version: version_time)
    ActsAsTbackend::Fact.build(id: id, store: STORE, key: "#{STORE}:#{i}",
                               value: { "i" => i, "payload" => "x" * 32 }, valid_time: version_time)
  end

  report[:passes] = (1..o[:passes]).map { |_| summarize(run_pass(facts, o[:threads]), o[:writes]) }
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

if o[:json]
  puts JSON.generate(report)
else
  puts "== load proof #{o[:label]} =="
  puts "config: #{report[:config]}"
  puts "daemon: pid=#{pid} port=#{port}"
  report[:passes].each_with_index do |s, i|
    puts "-- pass #{i + 1} --"
    puts "  writes=#{s[:writes]} elapsed=#{s[:elapsed_s]}s  #{s[:writes_per_sec]}/s  #{s[:rpm]} rpm"
    puts "  latency ms: p50=#{s[:p50_ms]} p95=#{s[:p95_ms]} p99=#{s[:p99_ms]} max=#{s[:max_ms]}"
    puts "  statuses: #{s[:statuses]}"
  end
  puts JSON.generate(report)
end
