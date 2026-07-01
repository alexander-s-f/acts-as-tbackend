# frozen_string_literal: true

# LEGACY (pre-refresh) — verifies the old shadow_comparison path against the pre-refresh
# API and is NOT part of the refreshed core. Pending port to the new core. Reference only.

require "json"
require "socket"
require "zlib"
require "fileutils"
require "securerandom"

# Require our library
require_relative "lib/acts_as_tbackend"

# ANSI text styling
GREEN   = "\e[32m"
RED     = "\e[31m"
CYAN    = "\e[36m"
YELLOW  = "\e[33m"
BOLD    = "\e[1m"
RESET   = "\e[0m"

$failed_tests = 0

def assert(cond, msg = "Assertion failed")
  if cond
    puts "  #{GREEN}✔ PASS:#{RESET} #{msg}"
  else
    puts "  #{RED}✘ FAIL:#{RESET} #{msg}"
    $failed_tests += 1
  end
end

def assert_equal(expected, actual, msg = "Assertion failed")
  if expected == actual
    puts "  #{GREEN}✔ PASS:#{RESET} #{msg}"
  else
    puts "  #{RED}✘ FAIL:#{RESET} #{msg} - Expected: #{expected.inspect}, Got: #{actual.inspect}"
    $failed_tests += 1
  end
end

# TCP helper to check if a port is open
def port_open?(ip, port)
  begin
    TCPSocket.new(ip, port).close
    true
  rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH
    false
  end
end

puts "\n#{BOLD}#{CYAN}=== ACTIVE RECORD SHADOW COMPARISON VERIFICATION SUITE ===#{RESET}"

# 1. Compile the Rust TBackend server and igniter-vm to make sure we are running the latest binaries
puts "\n[Compiling] Compiling igniter-vm and igniter-tbackend..."
system("cargo build --release", chdir: File.expand_path("../igniter-vm", __dir__))
system("RUSTFLAGS='-C link-arg=-undefined -C link-arg=dynamic_lookup' cargo build --release", chdir: File.expand_path("../igniter-tbackend", __dir__))

# 2. Spawn the TBackend daemon in background on port 7415
puts "\n[TBackend Daemon] Spawning daemon in the background on port 7415..."
daemon_bin = File.expand_path("../igniter-tbackend/target/release/tbackend", __dir__)
daemon_pid = spawn("#{daemon_bin} --host 127.0.0.1 --port 7415 --data-dir nil --pool-size 4", out: "/dev/null", err: "/dev/null")

# Allow socket to bind
15.times do
  break if port_open?("127.0.0.1", 7415)
  sleep 0.1
end

assert(port_open?("127.0.0.1", 7415), "TBackend daemon successfully bound to port 7415 and is online")

begin
  client = ActsAsTbackend.client("127.0.0.1", 7415)
  assert(client.ping, "Client successfully handshaked with TBackend")

  # 3. Submit matching CRM result for BidSummary
  # BidSummary multiplies base_bid (10.50) and tax_rate (0.25) -> result (2.625)
  puts "\n[Shadow Comparison] Submitting MATCHING CRM result for BidSummary..."
  ActsAsTbackend::ShadowComparison.submit_crm_result(
    contract: "BidSummary",
    inputs: {
      base_bid: { value: 1050, scale: 2 },
      tax_rate: { value: 2500, scale: 4 }
    },
    result: { value: 2625000, scale: 6 },
    host: "127.0.0.1",
    port: 7415
  )

  # 4. Submit mismatching CRM result for BidSummary (to verify delta computation)
  # CRM computes 3.00, but VM computes 2.625 -> delta = 3.00 - 2.625 = 0.375
  puts "\n[Shadow Comparison] Submitting MISMATCHING CRM result for BidSummary..."
  ActsAsTbackend::ShadowComparison.submit_crm_result(
    contract: "BidSummary",
    inputs: {
      base_bid: { value: 1050, scale: 2 },
      tax_rate: { value: 2500, scale: 4 }
    },
    result: { value: 3000000, scale: 6 },
    host: "127.0.0.1",
    port: 7415
  )

  # 5. Wait for the async queue worker thread to execute both shadow verifications
  puts "\n[Async Queue] Waiting 1.5 seconds for background worker thread execution..."
  sleep 1.5

  # 6. Retrieve facts from TBackend store "shadow_results"
  puts "\n[Verification] Fetching comparison results from TBackend 'shadow_results' store..."
  facts = client.facts_for(store: "shadow_results")
  assert_equal(2, facts.size, "Exactly 2 shadow comparison facts were recorded in TBackend")

  if facts.size == 2
    # Sort by execution time to verify order
    sorted_facts = facts.sort_by { |f| f[:value][:executed_at] }
    match_fact = sorted_facts[0][:value]
    mismatch_fact = sorted_facts[1][:value]

    # Verify matching fact
    assert_equal("BidSummary", match_fact[:contract_name], "Matching fact has correct contract name")
    assert_equal(true, match_fact[:matched], "First comparison resulted in matched = true")
    assert_equal(nil, match_fact[:delta_json], "First comparison has nil delta_json")
    assert(match_fact[:latency_ms] > 0, "First comparison recorded positive execution latency: #{match_fact[:latency_ms]} ms")

    # Verify mismatching fact
    assert_equal("BidSummary", mismatch_fact[:contract_name], "Mismatching fact has correct contract name")
    assert_equal(false, mismatch_fact[:matched], "Second comparison resulted in matched = false")
    assert_equal(0.375, mismatch_fact[:delta_json][:diff], "Second comparison correctly calculated delta difference: 0.375")
  end

  # --- HARDENING TEST SUITE ---

  # 1. SHADOW_ENABLED = false
  puts "\n[Test: Disable Mode] Testing SHADOW_ENABLED = false..."
  ENV["SHADOW_ENABLED"] = "false"
  begin
    assert_equal(false, ActsAsTbackend.enabled?, "ActsAsTbackend.enabled? is false when SHADOW_ENABLED=false")
    c_disabled = ActsAsTbackend.client("127.0.0.1", 7415)
    assert_equal(false, c_disabled.ping, "Disabled client ping returns false")
    assert_equal(nil, c_disabled.write_fact(store: "x", key: "y", value: {}), "Disabled client write_fact returns nil")
  ensure
    ENV.delete("SHADOW_ENABLED")
  end

  # 2. Circuit Breaker
  puts "\n[Test: Circuit Breaker] Testing circuit breaker transition on consecutive failures..."
  ENV["SHADOW_CIRCUIT_BREAKER_FAILURES"] = "3"
  ENV["SHADOW_CIRCUIT_BREAKER_COOLDOWN"] = "5.0"
  ENV["SHADOW_TIMEOUT"] = "0.2"
  begin
    # Clear any cached pools/breakers
    ActsAsTbackend.close_all_clients
    dead_client = ActsAsTbackend.client("127.0.0.1", 7499)

    # 3 failures should trip the breaker
    3.times do |i|
      res = dead_client.ping
      assert_equal(false, res, "Failure #{i+1} handled silently")
    end

    breaker = ActsAsTbackend.circuit_breaker_for("127.0.0.1", 7499)
    assert_equal(:open, breaker.state, "Circuit breaker tripped to :open state after 3 failures")

    # 4th request should short-circuit instantly
    t_start = Time.now
    res4 = dead_client.ping
    t_elapsed = Time.now - t_start
    assert_equal(false, res4, "Short-circuited ping returned false")
    assert(t_elapsed < 0.05, "Short-circuit execution bypassed socket connect instantly (elapsed: #{t_elapsed.round(4)}s)")
  ensure
    ENV.delete("SHADOW_CIRCUIT_BREAKER_FAILURES")
    ENV.delete("SHADOW_CIRCUIT_BREAKER_COOLDOWN")
    ENV.delete("SHADOW_TIMEOUT")
    ActsAsTbackend.close_all_clients
  end

  # 3. Connection Pool Timeout
  puts "\n[Test: Connection Pool Timeout] Testing pool exhaustion checkout timeout..."
  ENV["SHADOW_POOL_SIZE"] = "1"
  ENV["SHADOW_POOL_TIMEOUT"] = "0.5"
  begin
    ActsAsTbackend.close_all_clients
    pool = ActsAsTbackend.pool_for("127.0.0.1", 7415)

    # Borrow the only connection
    conn1 = pool.checkout

    t_start = Time.now
    t = Thread.new do
      begin
        pool.checkout
        :success
      rescue Timeout::Error
        :timeout
      end
    end

    res = t.value
    t_elapsed = Time.now - t_start
    assert_equal(:timeout, res, "Subsequent checkout timed out as expected")
    assert(t_elapsed >= 0.4, "Checkout blocked and waited for connection (elapsed: #{t_elapsed.round(4)}s)")

    pool.checkin(conn1)
  ensure
    ENV.delete("SHADOW_POOL_SIZE")
    ENV.delete("SHADOW_POOL_TIMEOUT")
    ActsAsTbackend.close_all_clients
  end

  # 4. Socket Read Timeout
  puts "\n[Test: Socket Timeout] Testing socket read timeout..."
  ENV["SHADOW_TIMEOUT"] = "0.3"
  begin
    hanging_server = TCPServer.new("127.0.0.1", 7488)
    hanging_client = ActsAsTbackend.client("127.0.0.1", 7488)
    server_thread = Thread.new { hanging_server.accept rescue nil }

    t_start = Time.now
    res = hanging_client.ping
    t_elapsed = Time.now - t_start

    assert_equal(false, res, "Hanging server request handled silently")
    assert(t_elapsed >= 0.2 && t_elapsed <= 0.6, "Socket read timed out after #{ENV["SHADOW_TIMEOUT"]}s (elapsed: #{t_elapsed.round(4)}s)")
  ensure
    ENV.delete("SHADOW_TIMEOUT")
    hanging_server&.close rescue nil
    server_thread&.kill rescue nil
    ActsAsTbackend.close_all_clients
  end

ensure
  # 7. Teardown
  puts "\n[Teardown] Shutting down daemon on port 7415..."
  ActsAsTbackend.shutdown_worker
  ActsAsTbackend.close_all_clients
  if daemon_pid
    begin
      Process.kill("INT", daemon_pid)
      Process.wait(daemon_pid)
    rescue => e
      # Ignore if already dead
    end
  end
end

puts "\n#{BOLD}#{CYAN}=== FINAL RESULTS ===#{RESET}"
if $failed_tests == 0
  puts "#{GREEN}🏆 ALL SHADOW COMPARISON TESTS PASSED SUCCESSFULLY!#{RESET}\n"
  exit(0)
else
  puts "#{RED}✘ Shadow Comparison Test Suite FAILED with #{$failed_tests} failure(s).#{RESET}\n"
  exit(1)
end
