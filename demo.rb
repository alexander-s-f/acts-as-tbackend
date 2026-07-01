# frozen_string_literal: true

# LEGACY (pre-refresh) — in-memory ActiveRecord demo against the old ActsAsTbackend API.
# NOT part of the refreshed core. Pending port to the new core. Reference only.

require "bundler/inline"

puts "Initializing Bundle dependencies (ActiveRecord + SQLite3)..."
gemfile(true) do
  source "https://rubygems.org"
  gem "activerecord", "~> 7.0"
  gem "sqlite3", "~> 1.4"
end

require "active_record"
require "fileutils"
require_relative "lib/acts_as_tbackend"

# ANSI text styling module
module Style
  RESET   = "\e[0m"
  BOLD    = "\e[1m"
  GRAY    = "\e[90m"
  RED     = "\e[31m"
  GREEN   = "\e[32m"
  YELLOW  = "\e[33m"
  BLUE    = "\e[34m"
  MAGENTA = "\e[35m"
  CYAN    = "\e[36m"
  WHITE   = "\e[37m"
end

# 1. Establish In-Memory SQLite database connection
puts "\n#{Style::BOLD}#{Style::CYAN}=== STEP 1: Booting SQLite Database ===#{Style::RESET}"
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")

# 2. Run schema migration
ActiveRecord::Schema.define do
  create_table :products, id: :string, force: true do |t|
    t.string :name
    t.decimal :price, precision: 10, scale: 2
    t.timestamps
  end
end
puts "#{Style::GREEN}✔ SQLite Schema migrated successfully (In-Memory)!#{Style::RESET}"

# 3. Dynamic in-process bootstrap of the local lab TBackend TCP server.
puts "\n#{Style::BOLD}#{Style::CYAN}=== STEP 2: Booting Rust TBackend Server in Background ===#{Style::RESET}"
require_relative "../igniter-tbackend/tbackend_ruby_extension"
begin
  TBackendRubyExtension.build_and_require!(root: File.expand_path("../igniter-tbackend", __dir__))
rescue => e
  puts "#{Style::RED}Failed to load the local TBackend extension: #{e.message}#{Style::RESET}"
  exit 1
end

# Spin up the lab TCP server on port 7409 in in-memory mode (nil data_dir), pool size 4.
puts "[Rust Engine] Spawning concurrent TCP Server on port 7409..."
rust_server = Igniter::TBackendPlayground::Server.start("127.0.0.1", 7409, nil, 4)
sleep 0.2
puts "#{Style::GREEN}✔ Rust TCP Server is online and listening.#{Style::RESET}"

# 4. Define ActiveRecord Model using acts_as_tbackend
class Product < ActiveRecord::Base
  self.primary_key = :id

  # Connect ActiveRecord hooks to TBackend products_ledger store
  acts_as_tbackend store: "products_ledger", port: 7409
end

# Helper to render facts in a readable terminal table.
def print_fact_table(title, facts)
  puts "\n#{Style::BOLD}#{Style::MAGENTA}#{title}#{Style::RESET}"
  puts "#{Style::BOLD}#{Style::CYAN}┌──────────┬────────────┬────────────────────────────┬─────────────────────────────┬──────────────────┐#{Style::RESET}"
  puts "#{Style::BOLD}#{Style::CYAN}│ ID (8)   │ KEY        │ VALUE HASH                 │ TRANSACTION TIME            │ VALID TIME       │#{Style::RESET}"
  puts "#{Style::BOLD}#{Style::CYAN}├──────────┼────────────┼────────────────────────────┼─────────────────────────────┼──────────────────┤#{Style::RESET}"
  
  facts.each do |fact|
    id = fact[:id][0..7]
    key = fact[:key].to_s[0..9].ljust(10)
    hash = fact[:value_hash].to_s[0..24].ljust(26)
    tt = Time.at(fact[:transaction_time]).strftime("%Y-%m-%d %H:%M:%S")
    vt = fact[:valid_time] ? Time.at(fact[:valid_time]).strftime("%Y-%m-%d %H:%M") : "Present"
    vt = vt.ljust(16)

    printf("#{Style::CYAN}│#{Style::RESET} %-8s #{Style::CYAN}│#{Style::RESET} %-10s #{Style::CYAN}│#{Style::RESET} %-26s #{Style::CYAN}│#{Style::RESET} %-27s #{Style::CYAN}│#{Style::RESET} %-16s #{Style::CYAN}│#{Style::RESET}\n",
           id, key, hash, tt, vt)
    
    # Print indented JSON payload
    puts "#{Style::CYAN}│#{Style::RESET}          #{Style::BOLD}PAYLOAD: #{Style::RESET}#{Style::GRAY}#{fact[:value].to_json}#{Style::RESET}".ljust(102) + "#{Style::CYAN}│#{Style::RESET}"
    puts "#{Style::CYAN}├──────────┴────────────┴────────────────────────────┴─────────────────────────────┴──────────────────┤#{Style::RESET}" unless fact == facts.last
  end
  
  puts "#{Style::BOLD}#{Style::CYAN}└──────────┴────────────┴────────────────────────────┴─────────────────────────────┴──────────────────┘#{Style::RESET}\n"
end

# Helper to print lineage audit tree
def print_history_tree(facts)
  return if facts.empty?
  first = facts.first
  puts "#{Style::BOLD}#{Style::YELLOW}Lineage Revision Tree: #{first[:store]} / #{first[:key]}#{Style::RESET}"
  
  facts.each_with_index do |fact, idx|
    if idx > 0
      puts "  #{Style::CYAN}│#{Style::RESET}"
      puts "  #{Style::CYAN}▼ (Causal Chain Link)#{Style::RESET}"
    end
    
    puts "#{Style::BOLD}#{Style::GREEN}● [Revision ##{idx + 1}]#{Style::RESET} #{Style::GRAY}(id: #{fact[:id][0..7]}...)#{Style::RESET}"
    puts "  ├── #{Style::BOLD}Transaction Time:#{Style::RESET} #{Time.at(fact[:transaction_time]).strftime('%Y-%m-%d %H:%M:%S')}"
    vt_str = fact[:valid_time] ? "#{Time.at(fact[:valid_time]).strftime('%Y-%m-%d %H:%M')} #{Style::BOLD}#{Style::YELLOW}(Bitemporal Adjustment)#{Style::RESET}" : "#{Style::GRAY}Present (Chronological)#{Style::RESET}"
    puts "  ├── #{Style::BOLD}Valid Time:      #{Style::RESET}#{vt_str}"
    cause_str = fact[:causation] ? "#{fact[:causation][0..7]}..." : "#{Style::GRAY}(Genesis)#{Style::RESET}"
    puts "  └── #{Style::BOLD}Causation Link:  #{Style::RESET}#{cause_str}"
    puts "      #{Style::GRAY}Payload:#{Style::RESET} #{fact[:value].to_json}"
  end
  puts ""
end

begin
  # 5. ActiveRecord lifecycle triggers
  puts "\n#{Style::BOLD}#{Style::CYAN}=== STEP 3: Executing ActiveRecord CRUD Workflows ===#{Style::RESET}"

  # Scenario A: Create a product
  puts "\n[ActiveRecord] Creating Product prod-100: 'Cyberpunk Neural Link' at $1500..."
  product = Product.create!(id: "prod-100", name: "Cyberpunk Neural Link", price: 1500.0)
  sleep 0.1

  # Scenario B: Update product price chronologically
  puts "\n[ActiveRecord] Updating Product price to $1800 (Market Inflation)..."
  product.update!(price: 1800.0)
  sleep 0.1

  # Scenario C: Perform a backdated / retroactive bitemporal price adjustment
  # Suppose we made a billing error and the price should have been $1200 starting from 1 hour ago
  t_retro = Time.now - 3600
  puts "\n[ActiveRecord] Performing Retroactive Price Adjustment to $1200 (Valid-Time: #{t_retro.strftime('%Y-%m-%d %H:%M')})..."
  product.price = 1200.0
  product.valid_time = t_retro
  product.save!
  sleep 0.1

  # 6. Audit historical projections
  puts "\n#{Style::BOLD}#{Style::CYAN}=== STEP 4: Querying Bitemporal Audits & Time-Travel Projections ===#{Style::RESET}"
  
  # Audit 1: Current state in SQLite
  puts "\n[SQLite View] Present product details:"
  sql_p = Product.find("prod-100")
  puts "  ID:    #{sql_p.id}"
  puts "  Name:  #{sql_p.name}"
  puts "  Price: #{Style::BOLD}$#{sql_p.price}#{Style::RESET}"

  # Audit 2: Retrieve full bitemporal timeline from TBackend
  history = Product.tbackend_history("prod-100")
  print_fact_table("Audit Timeline from TBackend Ledger:", history)
  print_history_tree(history)

  # Audit 3: Time travel pointwise query
  # Let's see what the price looked like *before* we performed the retroactive adjustment
  # We query transaction-time as of just before the third update was written (approx midpoint in transaction time)
  t_mid = history[1][:transaction_time] + 0.05
  puts "\n[Time-Travel] Querying as-of transaction time: #{Time.at(t_mid).strftime('%Y-%m-%d %H:%M:%S')}"
  mid_fact = Product.tbackend_latest_for("prod-100", as_of: t_mid)
  if mid_fact
    puts "  Projected Price: #{Style::BOLD}$#{mid_fact[:value][:price]}#{Style::RESET} (Valid: #{mid_fact[:valid_time] ? Time.at(mid_fact[:valid_time]).strftime('%Y-%m-%d %H:%M') : 'Present'})"
  else
    puts "  No fact found."
  end

  # Scenario D: Soft-Deletion Tombstone Fact
  puts "\n#{Style::BOLD}#{Style::CYAN}=== STEP 5: Tombstone facts on Destroy ===#{Style::RESET}"
  puts "\n[ActiveRecord] Deleting Product prod-100..."
  product.destroy!
  sleep 0.1

  # Verify product is gone from SQLite
  puts "\n[SQLite View] Product search after destroy:"
  begin
    Product.find("prod-100")
  rescue ActiveRecord::RecordNotFound
    puts "  #{Style::GREEN}✔ Product prod-100 was successfully deleted from SQLite!#{Style::RESET}"
  end

  # Verify TBackend still holds the full bitemporal audit path including the tombstone!
  full_history = Product.tbackend_history("prod-100")
  print_fact_table("Audit Timeline from TBackend after deletion (including tombstone):", full_history)

ensure
  # 7. Gracefully shutdown background Rust TCP server
  puts "\n#{Style::BOLD}#{Style::CYAN}=== STEP 6: Graceful Shutdown ===#{Style::RESET}"
  puts "[Rust Engine] Stopping background TCP server..."
  rust_server.stop rescue nil
  ActsAsTbackend.close_all_clients
  puts "#{Style::GREEN}✔ Rust TCP Server offline. Demo complete!#{Style::RESET}\n\n"
end
