# frozen_string_literal: true

require_relative "acts_as_tbackend/client"
require_relative "acts_as_tbackend/extension"
require_relative "acts_as_tbackend/shadow_comparison"

module ActsAsTbackend
  class QueueWorker
    def initialize
      @queue = Queue.new
      @thread = Thread.new { run_loop }
    end

    def push(task)
      @queue.push(task)
    end

    def stop
      @queue.push(:stop)
      @thread.join rescue nil
    end

    private

    def run_loop
      loop do
        task = @queue.pop
        break if task == :stop

        begin
          task.call
        rescue => e
          if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
            Rails.logger.error("[ActsAsTbackend::QueueWorker] Error executing background task: #{e.message}\n#{e.backtrace.join("\n")}")
          else
            warn "[ActsAsTbackend::QueueWorker] Error executing background task: #{e.message}"
          end
        end
      end
    end
  end
end

require "timeout"

module ActsAsTbackend
  class ConnectionPool
    def initialize(size:, timeout:, &block)
      @size = size
      @timeout = timeout
      @block = block
      @connections = []
      @available = []
      @mutex = Mutex.new
      @cond = ConditionVariable.new
    end

    def with_connection
      conn = checkout
      begin
        yield conn
      ensure
        checkin(conn)
      end
    end

    def checkout
      start_time = Time.now
      @mutex.synchronize do
        loop do
          if conn = @available.pop
            return conn
          end

          if @connections.size < @size
            conn = @block.call
            @connections << conn
            return conn
          end

          elapsed = Time.now - start_time
          remaining = @timeout - elapsed
          if remaining <= 0
            raise Timeout::Error, "Connection pool checkout timeout exceeded"
          end

          @cond.wait(@mutex, remaining)
        end
      end
    end

    def checkin(conn)
      @mutex.synchronize do
        @available << conn
        @cond.signal
      end
    end

    def clear
      @mutex.synchronize do
        @connections.each(&:close) rescue nil
        @connections.clear
        @available.clear
      end
    end
  end

  class CircuitBreaker
    attr_reader :failures, :state, :last_failure_time

    def initialize(max_failures: 3, cooldown: 10.0)
      @max_failures = max_failures
      @cooldown = cooldown
      @failures = 0
      @state = :closed # :closed, :open, :half_open
      @last_failure_time = nil
      @mutex = Mutex.new
    end

    def record_success
      @mutex.synchronize do
        @failures = 0
        @state = :closed
      end
    end

    def record_failure
      @mutex.synchronize do
        @failures += 1
        @last_failure_time = Time.now
        if @failures >= @max_failures
          @state = :open
        end
      end
    end

    def allow_request?
      @mutex.synchronize do
        case @state
        when :closed
          true
        when :open
          if Time.now - @last_failure_time > @cooldown
            @state = :half_open
            true
          else
            false
          end
        when :half_open
          true
        end
      end
    end
  end

  class ClientProxy
    def initialize(host, port)
      @host = host
      @port = port
    end

    def method_missing(method, *args, **kwargs, &block)
      pool = ActsAsTbackend.pool_for(@host, @port)
      pool.with_connection do |client|
        client.send(method, *args, **kwargs, &block)
      end
    end

    def respond_to_missing?(method, include_private = false)
      Client.instance_methods.include?(method) || super
    end
  end

  class DummyClient
    def ping; false; end
    def write_fact(*args, **kwargs); nil; end
    def latest_for(*args, **kwargs); nil; end
    def facts_for(*args, **kwargs); []; end
    def query_scope(*args, **kwargs); []; end
    def size(*args, **kwargs); 0; end
    def stores; []; end
    def close; nil; end
  end

  class SidekiqJob
    def self.include_sidekiq_if_needed
      if defined?(::Sidekiq::Job) && !ancestors.include?(::Sidekiq::Job)
        include ::Sidekiq::Job
      elsif defined?(::Sidekiq::Worker) && !ancestors.include?(::Sidekiq::Worker)
        include ::Sidekiq::Worker
      end
    end

    def perform(type, args)
      case type
      when "write_fact"
        opts = args["opts"]
        fact_data = args["fact"]
        client = ActsAsTbackend.client(opts["host"], opts["port"])
        client.write_fact(
          store: fact_data["store"],
          key: fact_data["key"],
          value: fact_data["value"],
          causation: fact_data["causation"],
          valid_time: fact_data["valid_time"]
        )
      when "shadow_comparison"
        contract = args["contract"]
        inputs = args["inputs"]
        result = args["result"]
        opts = args["opts"]
        ShadowComparison.execute_comparison(
          contract: contract,
          inputs: inputs,
          result: result,
          **opts.transform_keys(&:to_sym)
        )
      end
    rescue => e
      warn "[ActsAsTbackend::SidekiqJob] Error executing job #{type}: #{e.message}"
    end
  end

  class << self
    def enabled?
      ENV["SHADOW_ENABLED"] != "false"
    end

    def async_mode
      (ENV["SHADOW_ASYNC_MODE"] || "thread").to_sym
    end

    def pools
      @pools ||= {}
    end

    def pool_for(host, port)
      @pool_mutex ||= Mutex.new
      @pool_mutex.synchronize do
        key = "#{host}:#{port}"
        pools[key] ||= ConnectionPool.new(
          size: ENV["SHADOW_POOL_SIZE"] ? ENV["SHADOW_POOL_SIZE"].to_i : 5,
          timeout: ENV["SHADOW_POOL_TIMEOUT"] ? ENV["SHADOW_POOL_TIMEOUT"].to_f : 5.0
        ) do
          Client.new(host, port)
        end
      end
    end

    def circuit_breakers
      @circuit_breakers ||= {}
    end

    def circuit_breaker_for(host, port)
      @breaker_mutex ||= Mutex.new
      @breaker_mutex.synchronize do
        key = "#{host}:#{port}"
        circuit_breakers[key] ||= CircuitBreaker.new(
          max_failures: ENV["SHADOW_CIRCUIT_BREAKER_FAILURES"] ? ENV["SHADOW_CIRCUIT_BREAKER_FAILURES"].to_i : 3,
          cooldown: ENV["SHADOW_CIRCUIT_BREAKER_COOLDOWN"] ? ENV["SHADOW_CIRCUIT_BREAKER_COOLDOWN"].to_f : 10.0
        )
      end
    end

    def client(host = nil, port = nil)
      unless enabled?
        return DummyClient.new
      end

      # Fallback chain: dynamic override -> ENV config -> default config
      h = ENV["SHADOW_HOST"] || host || "127.0.0.1"
      p = ENV["SHADOW_PORT"] ? ENV["SHADOW_PORT"].to_i : (port || 7401)

      ClientProxy.new(h, p)
    end

    def close_all_clients
      pools.each_value(&:clear)
      pools.clear
    end

    def worker
      if @worker_pid != Process.pid || @worker.nil?
        @worker = QueueWorker.new
        @worker_pid = Process.pid
      end
      @worker
    end

    def enqueue(&block)
      worker.push(block)
    end

    def enqueue_job(type, args)
      unless enabled?
        return
      end

      if async_mode == :sidekiq && (defined?(::Sidekiq::Job) || defined?(::Sidekiq::Worker))
        SidekiqJob.include_sidekiq_if_needed
        SidekiqJob.perform_async(type, args)
      else
        enqueue do
          begin
            case type
            when "write_fact"
              opts = args[:opts] || args["opts"]
              fact_data = args[:fact] || args["fact"]
              c = client(opts[:host] || opts["host"], opts[:port] || opts["port"])
              
              prev_fact = c.latest_for(store: fact_data[:store] || fact_data["store"], key: fact_data[:key] || fact_data["key"]) rescue nil
              causation = prev_fact ? prev_fact[:id] : nil

              c.write_fact(
                store: fact_data[:store] || fact_data["store"],
                key: fact_data[:key] || fact_data["key"],
                value: fact_data[:value] || fact_data["value"],
                causation: causation,
                valid_time: fact_data[:valid_time] || fact_data["valid_time"]
              )
            when "shadow_comparison"
              contract = args[:contract] || args["contract"]
              inputs = args[:inputs] || args["inputs"]
              result = args[:result] || args["result"]
              opts = args[:opts] || args["opts"]
              sym_opts = {}
              opts.each { |k, v| sym_opts[k.to_sym] = v }
              ShadowComparison.execute_comparison(
                contract: contract,
                inputs: inputs,
                result: result,
                **sym_opts
              )
            end
          rescue => e
            warn "[ActsAsTbackend] Background async job #{type} failed: #{e.message}"
          end
        end
      end
    end

    def shutdown_worker
      @worker&.stop
      @worker = nil
      @worker_pid = nil
    end
  end
end

# Hook into ActiveRecord when loaded
if defined?(ActiveSupport) && ActiveSupport.respond_to?(:on_load)
  ActiveSupport.on_load(:active_record) do
    include ActsAsTbackend::Extension
  end
elsif defined?(ActiveRecord::Base)
  ActiveRecord::Base.include ActsAsTbackend::Extension
end
