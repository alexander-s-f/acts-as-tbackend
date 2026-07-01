# frozen_string_literal: true

require_relative "lib/acts_as_tbackend/version"

Gem::Specification.new do |spec|
  spec.name        = "acts-as-tbackend"
  spec.version     = ActsAsTbackend::VERSION
  spec.authors     = ["Avenlance"]
  spec.summary     = "Production Ruby connector for the TBackend temporal-ledger daemon."
  spec.description = "Pooled, circuit-broken, idempotent client for TBackend: persistent framed " \
                     "sockets, write_fact_once with deterministic ids, token auth, and a " \
                     "connection pool sized for multi-threaded Rails."
  spec.homepage    = "https://git.int.avenlance.com/Igniter/acts-as-tbackend"
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.0"

  # Private Forgejo RubyGems registry. `allowed_push_host` blocks an accidental push to
  # the public rubygems.org — this gem is internal-only.
  spec.metadata = {
    "allowed_push_host" => "https://git.int.avenlance.com/api/packages/Igniter/rubygems",
    "homepage_uri"      => spec.homepage,
    "source_code_uri"   => spec.homepage
  }

  spec.files = Dir["lib/**/*.rb", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "connection_pool", "~> 2.4"
end
