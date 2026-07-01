# frozen_string_literal: true

require "json"
require "socket"
require "timeout"
require "zlib"

module ActsAsTbackend
  # One persistent framed connection to a TBackend daemon. Protocol parity with the
  # canonical P16 client (token, write_fact_once, rich status mapping,
  # Unavailable/Unknown split) — but the socket is **kept open and reused** across
  # requests (reconnect only on error), which is what makes pooled throughput cheap.
  #
  # NOT thread-safe: one in-flight request per connection. Concurrency is the Pool's
  # job — check a Connection out, use it, check it back in.
  class Connection
    DEFAULT_HOST = "127.0.0.1"
    DEFAULT_PORT = 7401
    MAX_FRAME_BYTES = 64 * 1024 * 1024

    class TransportUnavailable < StandardError; end # connect failed — nothing was sent
    class TransportUnknown < StandardError; end     # sent, no ack — may or may not have committed
    class InvalidFrame < StandardError; end

    def initialize(host: DEFAULT_HOST, port: DEFAULT_PORT, token: nil,
                   connect_timeout: 1.0, request_timeout: 2.0,
                   durability_default: "accepted", strict: false)
      @host = host
      @port = Integer(port)
      @token = token
      @connect_timeout = Float(connect_timeout)
      @request_timeout = Float(request_timeout)
      @durability_default = durability_default
      @strict = strict
      @socket = nil
    end

    def ping(timeout: nil)
      map_generic(request({ op: "ping" }, timeout))
    end

    # Idempotent durable write — the recommended write path. Derive `fact["id"]`
    # deterministically (see Fact.derive_id) so a retry is a replay, not a duplicate.
    def write_fact_once(fact, durability: nil, timeout: nil)
      req = { op: "write_fact_once", fact: fact, durability: durability || @durability_default }
      map_write_once(request(req, timeout))
    end

    # Bounded retry of write_fact_once for the retry-safe transient states
    # (rejected_before_commit / timeout_unknown). Never loops unbounded.
    def write_fact_once_safe(fact, durability: nil, timeout: nil, attempts: 2, backoff: 0.05)
      max = [Integer(attempts), 1].max
      seen = []
      max.times do |i|
        result = write_fact_once(fact, durability: durability, timeout: timeout)
        seen << summary(result)
        return result.merge(attempt_count: seen.length, attempts: seen) unless retry_safe?(result[:status]) && i + 1 < max

        sleep(backoff.to_f) if backoff.to_f.positive?
      end
    end

    def latest_for(store:, key:, as_of: nil, timeout: nil)
      req = { op: "latest_for", store: store.to_s, key: key.to_s }
      req[:as_of] = as_of unless as_of.nil?
      map_generic(request(req, timeout))
    end

    def facts_for(store:, key: nil, since: nil, as_of: nil, timeout: nil)
      req = { op: "facts_for", store: store.to_s }
      req[:key] = key.to_s unless key.nil?
      req[:since] = since unless since.nil?
      req[:as_of] = as_of unless as_of.nil?
      map_generic(request(req, timeout))
    end

    # Clock-free ordered read (the ordering authority). Prefer this over timestamp
    # ordering for replay/audit/pull.
    def facts_by_seq(store:, after_seq: 0, until_seq: nil, timeout: nil)
      req = { op: "facts_by_seq", store: store.to_s, after_seq: after_seq }
      req[:until_seq] = until_seq unless until_seq.nil?
      map_generic(request(req, timeout))
    end

    def close
      @socket&.close
    rescue StandardError
      nil
    ensure
      @socket = nil
    end

    private

    # Returns { transport_ok: true, response: <hash> } on a completed round-trip, or a
    # soft transport result (unavailable / timeout_unknown). Raises in strict mode.
    def request(req, timeout)
      raw = raw_request(with_token(req), request_timeout(timeout))
      { transport_ok: true, response: raw }
    rescue TransportUnavailable => e
      raise if @strict

      transport_result("unavailable", e, retryable: true)
    rescue TransportUnknown => e
      raise if @strict

      transport_result("timeout_unknown", e, retryable: nil)
    end

    def raw_request(req, timeout)
      sock = live_socket
      Timeout.timeout(timeout) do
        sock.write(encode_frame(req))
        decode_frame(sock)
      end
    rescue Timeout::Error, EOFError, IOError, SystemCallError, JSON::ParserError, InvalidFrame => e
      close # desynced/broken socket — force reconnect next time
      raise TransportUnknown, e.message
    end

    def live_socket
      return @socket if @socket && !@socket.closed?

      @socket = open_socket
    end

    def open_socket
      socket = nil
      Timeout.timeout(@connect_timeout) { socket = TCPSocket.new(@host, @port) }
      socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, true)
      socket
    rescue Timeout::Error, SocketError, SystemCallError => e
      raise TransportUnavailable, e.message
    end

    def with_token(req)
      return req unless @token && !@token.to_s.empty?
      return req if req.key?(:token) || req.key?("token")

      req.merge(token: @token)
    end

    def request_timeout(override)
      override.nil? ? @request_timeout : Float(override)
    end

    def encode_frame(req)
      body = JSON.generate(req).b
      [body.bytesize].pack("N") + body + [Zlib.crc32(body)].pack("N")
    end

    def decode_frame(socket)
      len = read_exact(socket, 4).unpack1("N")
      raise InvalidFrame, "response frame too large" if len > MAX_FRAME_BYTES

      body = read_exact(socket, len)
      expected = read_exact(socket, 4).unpack1("N")
      raise InvalidFrame, "CRC mismatch" unless Zlib.crc32(body) == expected

      JSON.parse(body, symbolize_names: true)
    end

    def read_exact(socket, bytes)
      data = +"".b
      while data.bytesize < bytes
        chunk = socket.read(bytes - data.bytesize)
        raise EOFError, "socket closed" if chunk.nil? || chunk.empty?

        data << chunk
      end
      data
    end

    # ---- response mapping (parity with canonical client) ----

    def map_write_once(env)
      return env unless env[:transport_ok]

      r = env[:response]
      return rejected(r) if overloaded?(r)
      return dup_conflict(r) if r[:error_code] == "duplicate_fact_id_conflict"

      if r[:ok] == true && r[:committed] == true
        return result(true, "idempotent_replay", true, false, r, nil) if r[:idempotent_replay] == true

        return result(true, "committed_acked", true, false, r, nil)
      end
      generic_error(r)
    end

    def map_generic(env)
      return env unless env[:transport_ok]

      r = env[:response]
      return result(true, "ok", nil, false, r, nil) if r[:ok] == true
      return rejected(r) if overloaded?(r)

      generic_error(r)
    end

    def overloaded?(r)  = r[:error_code] == "overloaded" && r[:committed] == false
    def rejected(r)     = result(false, "rejected_before_commit", false, true, r, r[:error])
    def dup_conflict(r) = result(false, "duplicate_fact_id_conflict", false, false, r, r[:error])
    def generic_error(r) = result(false, "error", r[:committed], r[:retryable], r, r[:error])
    def transport_result(status, error, retryable:) = result(false, status, nil, retryable, nil, sanitize(error))

    def result(ok, status, committed, retryable, response, error)
      { ok: ok, status: status, committed: committed, retryable: retryable, response: response, error: error }
    end

    def retry_safe?(status)
      status == "rejected_before_commit" || status == "timeout_unknown"
    end

    def summary(result)
      { ok: result[:ok], status: result[:status], committed: result[:committed], retryable: result[:retryable] }
    end

    def sanitize(error)
      text = "#{error.class}: #{error.message}"
      return text unless @token && !@token.to_s.empty?

      text.gsub(@token.to_s, "[REDACTED]")
    end
  end
end
