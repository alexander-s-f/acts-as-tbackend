# frozen_string_literal: true

require "open3"
require "json"
require "tempfile"
require "digest"
require "securerandom"
require "time"

module ActsAsTbackend
  module ShadowComparison
    class << self
      # Submits a CRM result to be asynchronously compared against the Igniter VM execution.
      #
      # contract - String name of the contract (e.g., "BidSummary")
      # inputs   - Hash of input values (matching the contract's inputs signature)
      # result   - The result computed by the CRM (to compare against)
      # opts     - Hash of options (e.g., :host, :port)
      def submit_crm_result(contract:, inputs:, result:, **opts)
        return unless ActsAsTbackend.enabled?

        host = opts[:host] || "127.0.0.1"
        port = opts[:port] || 7401

        job_args = {
          contract: contract,
          inputs: inputs,
          result: result,
          opts: { host: host, port: port }
        }
        ActsAsTbackend.enqueue_job("shadow_comparison", job_args)
      end

      def execute_comparison(contract:, inputs:, result:, **opts)
        return unless ActsAsTbackend.enabled?

        host = opts[:host] || "127.0.0.1"
        port = opts[:port] || 7401

        begin
          # 1. Locate the compiled contract JSON under igniter-compiler/out/
          contract_filename = "#{contract.gsub(/(.)([A-Z])/, '\1_\2').downcase}.json"
          search_pattern = File.expand_path("../../../../igniter-compiler/out/*/contracts/#{contract_filename}", __FILE__)
          contract_path = Dir.glob(search_pattern).first

          unless contract_path && File.exist?(contract_path)
            # Also search fallback in Out conformance test directory or igniter-vm test fixtures
            fallback_pattern = File.expand_path("../../../../igniter-compiler/out_conformance_test/*/contracts/#{contract_filename}", __FILE__)
            contract_path = Dir.glob(fallback_pattern).first
          end

          raise "Could not locate compiled contract JSON for #{contract}" unless contract_path

          # 2. Write inputs to a temp file
          temp_inputs = Tempfile.new(["inputs", ".json"])
          temp_inputs.write(JSON.generate(inputs))
          temp_inputs.close

          # 3. Locate VM CLI binary and prepare command
          vm_bin = File.expand_path("../../../../igniter-vm/target/release/igniter-vm", __FILE__)
          unless File.exist?(vm_bin)
            # Check debug target fallback
            vm_bin = File.expand_path("../../../../igniter-vm/target/debug/igniter-vm", __FILE__)
          end

          cmd = [
            vm_bin, "run",
            "--contract", contract_path,
            "--inputs", temp_inputs.path,
            "--json",
            "-b", "#{host}:#{port}"
          ]

          # 4. Execute VM CLI
          start_time = Time.now
          stdout, stderr, status = Open3.capture3(*cmd)
          latency_ms = ((Time.now - start_time) * 1000).round(2)

          temp_inputs.unlink # Clean up temp inputs file

          # 5. Parse output and perform comparison
          if status.success?
            response = JSON.parse(stdout, symbolize_names: true)
            if response[:status] == "success"
              vm_result = response[:result]
              matched = results_match?(result, vm_result)
              delta = matched ? nil : compute_delta(result, vm_result)

              # Commit result fact to TBackend
              payload = {
                contract_name: contract,
                inputs_hash: Digest::SHA256.hexdigest(JSON.generate(inputs)),
                crm_result: result,
                igniter_result: vm_result,
                matched: matched,
                delta_json: delta,
                latency_ms: latency_ms,
                executed_at: Time.now.iso8601
              }

              client = ActsAsTbackend.client(host, port)
              client.write_fact(
                store: "shadow_results",
                key: SecureRandom.uuid,
                value: payload
              )
            else
              log_error("VM reported execution failure: #{response[:error]}", stderr)
            end
          else
            log_error("VM CLI exited with status #{status.exitstatus}", stderr)
          end
        rescue => e
          log_error("Error in ShadowComparison: #{e.message}\n#{e.backtrace.join("\n")}")
        end
      end

      private

      def results_match?(crm_val, vm_val)
        # Normalize and compare decimals vs normal numbers
        crm_norm = normalize_val(crm_val)
        vm_norm = normalize_val(vm_val)
        crm_norm == vm_norm
      end

      def normalize_val(val)
        if val.is_a?(Hash) && (val.key?(:value) || val.key?("value")) && (val.key?(:scale) || val.key?("scale"))
          # It's a decimal hash representation
          v = (val[:value] || val["value"]).to_i
          s = (val[:scale] || val["scale"]).to_i
          # Return float representation for comparison
          v.to_f / (10**s)
        elsif val.is_a?(Numeric)
          val.to_f
        elsif val.is_a?(String)
          val.strip
        elsif val.is_a?(Array)
          val.map { |item| normalize_val(item) }
        else
          val
        end
      end

      def compute_delta(crm_val, vm_val)
        crm_norm = normalize_val(crm_val)
        vm_norm = normalize_val(vm_val)

        if crm_norm.is_a?(Numeric) && vm_norm.is_a?(Numeric)
          { diff: (crm_norm - vm_norm).round(6) }
        else
          { crm: crm_val, vm: vm_val }
        end
      end

      def log_error(msg, stderr = nil)
        full_msg = "[ActsAsTbackend::ShadowComparison] #{msg}"
        full_msg += "\nSTDERR: #{stderr}" if stderr && !stderr.empty?

        if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
          Rails.logger.error(full_msg)
        else
          warn full_msg
        end
      end
    end
  end
end
