# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "acts_as_tbackend"
require "json"
require "socket"
require "zlib"
require "minitest/autorun"

# A fake socket that serves exactly one pre-framed daemon response, so Connection
# response-mapping can be tested without a live daemon.
class FakeSocket
  def initialize(response_hash)
    body = JSON.generate(response_hash).b
    @buf = [body.bytesize].pack("N") + body + [Zlib.crc32(body)].pack("N")
    @pos = 0
    @closed = false
  end

  def setsockopt(*); end

  def write(data)
    data.bytesize
  end

  def read(bytes)
    return nil if @pos >= @buf.bytesize

    chunk = @buf.byteslice(@pos, bytes)
    @pos += chunk.bytesize
    chunk
  end

  def closed?
    @closed
  end

  def close
    @closed = true
  end
end

module TestSupport
  module_function

  # A Connection whose socket is the given fake (no real daemon).
  def connection_with_response(response_hash, **opts)
    conn = ActsAsTbackend::Connection.new(**opts)
    fake = FakeSocket.new(response_hash)
    conn.define_singleton_method(:open_socket) { fake }
    conn
  end

  # Grab an ephemeral port then close it, so connecting to it is refused — a
  # deterministic "daemon down" without depending on a magic port number.
  def closed_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end
end

FakeRecord = Struct.new(:id, :updated_at, :attributes, keyword_init: true)
