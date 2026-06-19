# frozen_string_literal: true

require "socket"
require "json"
require "zlib"
require "digest"
require "securerandom"

module ActsAsTbackend
  class Client
    def initialize(host = "127.0.0.1", port = 7401)
      @host = host
      @port = port
      @socket = nil
    end

    def connect
      breaker = ActsAsTbackend.circuit_breaker_for(@host, @port)
      unless breaker.allow_request?
        raise "TBackend circuit breaker is OPEN for #{@host}:#{@port}"
      end

      begin
        timeout = ENV["SHADOW_TIMEOUT"] ? ENV["SHADOW_TIMEOUT"].to_f : 2.0
        @socket = Socket.tcp(@host, @port, connect_timeout: timeout)
        @socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, true)
      rescue => e
        breaker.record_failure
        raise "Could not connect to TBackend server at #{@host}:#{@port} - #{e.message}"
      end
    end

    def close
      @socket&.close rescue nil
      @socket = nil
    end

    def ping
      send_req(op: "ping")[:pong] == true
    end

    def write_fact(store:, key:, value:, causation: nil, valid_time: nil)
      sorted_val = sort_hash_keys(value)
      value_hash = Digest::SHA256.hexdigest(JSON.generate(sorted_val))

      fact = {
        id: SecureRandom.uuid,
        store: store.to_s,
        key: key.to_s,
        value: value,
        value_hash: value_hash,
        causation: causation,
        transaction_time: Time.now.to_f,
        valid_time: valid_time&.to_f,
        schema_version: 1,
        producer: "ActiveRecord Integration",
        derivation: nil
      }

      res = send_req(op: "write_fact", fact: fact)
      res[:ok] ? fact : raise("Failed to commit fact to TBackend: #{res[:error]}")
    end

    def latest_for(store:, key:, as_of: nil)
      res = send_req(op: "latest_for", store: store.to_s, key: key.to_s, as_of: as_of&.to_f)
      res[:ok] ? res[:fact] : nil
    end

    def facts_for(store:, key: nil, since: nil, as_of: nil)
      res = send_req(op: "facts_for", store: store.to_s, key: key&.to_s, since: since&.to_f, as_of: as_of&.to_f)
      res[:ok] ? res[:facts] : []
    end

    def query_scope(store:, filters: {}, as_of: nil)
      res = send_req(op: "query_scope", store: store.to_s, filters: filters, as_of: as_of&.to_f)
      res[:ok] ? res[:facts] : []
    end

    def size(store = nil)
      res = send_req(op: "size", store: store&.to_s)
      res[:ok] ? res[:size] : 0
    end

    def stores
      res = send_req(op: "stores")
      res[:ok] ? res[:stores] : []
    end

    private

    def write_with_timeout(data)
      timeout = ENV["SHADOW_TIMEOUT"] ? ENV["SHADOW_TIMEOUT"].to_f : 2.0
      remaining = data.bytesize
      offset = 0
      while remaining > 0
        ready = IO.select(nil, [@socket], nil, timeout)
        raise Timeout::Error, "Socket write timeout after #{timeout}s" unless ready
        written = @socket.write_nonblock(data.byteslice(offset, remaining), exception: false)
        if written == :wait_write
          next
        elsif written.nil?
          raise "Connection closed on write"
        end
        offset += written
        remaining -= written
      end
    end

    def read_exact_with_timeout(length)
      timeout = ENV["SHADOW_TIMEOUT"] ? ENV["SHADOW_TIMEOUT"].to_f : 2.0
      buffer = String.new(encoding: Encoding::BINARY)
      while buffer.bytesize < length
        needed = length - buffer.bytesize
        ready = IO.select([@socket], nil, nil, timeout)
        raise Timeout::Error, "Socket read timeout after #{timeout}s" unless ready
        chunk = @socket.read_nonblock(needed, exception: false)
        if chunk == :wait_readable
          next
        elsif chunk.nil?
          break
        end
        buffer << chunk
      end
      buffer
    end

    def send_req(req)
      connect if @socket.nil? || @socket.closed?

      body = JSON.generate(req).b
      frame = [body.bytesize].pack("N") << body << [Zlib.crc32(body)].pack("N")
      write_with_timeout(frame)

      header = read_exact_with_timeout(4)
      return { ok: false, error: "EOF from TBackend" } unless header && header.bytesize == 4

      len = header.unpack1("N")
      resp_body = read_exact_with_timeout(len)
      return { ok: false, error: "Truncated response body" } unless resp_body && resp_body.bytesize == len

      crc_bytes = read_exact_with_timeout(4)
      return { ok: false, error: "Truncated CRC packet" } unless crc_bytes && crc_bytes.bytesize == 4

      raise "CRC wire protocol verification failed" unless Zlib.crc32(resp_body) == crc_bytes.unpack1("N")

      res = JSON.parse(resp_body, symbolize_names: true)

      ActsAsTbackend.circuit_breaker_for(@host, @port).record_success
      res
    rescue => e
      close
      ActsAsTbackend.circuit_breaker_for(@host, @port).record_failure
      { ok: false, error: e.message }
    end

    def sort_hash_keys(val)
      if val.is_a?(Hash)
        val.map { |k, v| [k.to_s, sort_hash_keys(v)] }.sort.to_h
      elsif val.is_a?(Array)
        val.map { |item| sort_hash_keys(item) }
      else
        val
      end
    end
  end
end
