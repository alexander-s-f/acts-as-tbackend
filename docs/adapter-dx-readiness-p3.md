# Adapter DX Readiness (P3)

Card: `LAB-ACTS-AS-TBACKEND-ADAPTER-DX-READINESS-P3`
Status: readiness packet - no Hub/Spark/Avenlance code changes
Date: 2026-07-03
Author: Codex

## 0. Scope and authority

This packet designs the next `acts-as-tbackend` Rails-adapter DX slice. It is
not a production adoption card.

- Rails/Postgres remain application authority.
- TBackend remains a shadow/side ledger until explicit convergence and swap
  gates.
- Hub/Spark/Avenlance were inspected only for friction and posture; no business
  repo code is changed by this packet.
- The gem is not published by this card.

## 1. Live adapter surface

Verified in the standalone repo at
`/Users/alex/dev/projects/igniter-workspace/acts-as-tbackend`, HEAD `a70ad38`
before this packet.

| Surface | File | Current behavior |
| --- | --- | --- |
| Entry point | `lib/acts_as_tbackend.rb` | Requires the core client stack only; ActiveRecord is opt-in through `acts_as_tbackend/extension`. |
| Config | `lib/acts_as_tbackend/config.rb` | ENV-backed host/port/token/timeouts/pool/durability/strict/breaker/enabled/producer. Defaults: loopback `127.0.0.1:7401`, `TBACKEND_ENABLED=1`, `TBACKEND_STRICT=0`, durability `accepted`. |
| Connection | `lib/acts_as_tbackend/connection.rb` | Persistent framed socket, token injection, `write_fact_once`, `write_fact_once_safe`, `latest_for`, `facts_for`, `facts_by_seq`, soft result mapping. |
| Pool | `lib/acts_as_tbackend/pool.rb` | `connection_pool` wrapper, one checked-out `Connection` per thread, `shutdown` closes sockets. |
| Client | `lib/acts_as_tbackend/client.rb` | Thread-safe facade with circuit breaker; returns soft result hashes and short-circuits as `circuit_open`. |
| Fact | `lib/acts_as_tbackend/fact.rb` | Deterministic id helper and fact builder; intentionally omits `value_hash` because daemon canonical hash is authority. |
| Mirror | `lib/acts_as_tbackend/mirror.rb` | Plain Ruby record-to-fact helper plus synchronous soft `mirror!`. |
| ActiveRecord extension | `lib/acts_as_tbackend/extension.rb` | `acts_as_tbackend` macro wires synchronous `after_commit` create/update/destroy callbacks. |
| Legacy parity demo | `lib/acts_as_tbackend/shadow_comparison.rb`, `demo.rb`, `verify_shadow.rb` | Pre-refresh reference material, not loaded by the supported core entrypoint. |

Existing tests cover response mapping, circuit breaker open behavior,
deterministic fact ids, value filtering, tombstones, and disabled mirror no-op.

## 2. Package and compatibility state

Local gemspec:

- `ActsAsTbackend::VERSION = "0.2.1"`.
- `required_ruby_version >= 3.0`.
- `connection_pool >= 2.4`.
- `allowed_push_host = https://rubygems.org`.

Remote publication, verified 2026-07-03:

```text
gem search '^acts-as-tbackend$' --remote --all
=> acts-as-tbackend (0.2.0)
```

So `0.2.1` is local/repo state and is not yet published to RubyGems.

Sidekiq / `connection_pool` compatibility, verified 2026-07-03:

- `gem dependency '^sidekiq$' --remote --version '>= 8.1.0'` reports
  Sidekiq 8.1.x requiring `connection_pool >= 3.0.0`.
- `gem list connection_pool --remote --all` reports current 3.x releases
  (`3.0.0`, `3.0.1`, `3.0.2`) and 2.x releases.
- The adapter uses only `ConnectionPool.new`, `#with`, and `#shutdown`, so the
  local `>= 2.4` lower bound remains compatible with both older Rails apps and
  Sidekiq 8.1.x hosts that resolve `connection_pool` 3.x.

## 3. Highest-friction Rails integration points

Ranked from highest leverage to lower leverage:

1. **Outbox-first mirror mode.** Current `after_commit -> mirror!` performs a
   synchronous socket attempt on the Rails request path. It is soft, but still
   spends request latency and cannot retry later. A first-class local outbox
   shape would let apps commit business data plus a mirror intent, then flush
   outside the request path.
2. **Failure policy is implicit.** Today the defaults are safe (`strict=0`,
   soft result hashes, disabled no-op), but apps do not get a named policy like
   `:ignore`, `:warn`, `:raise_in_test`, or `:enqueue_retry`. That makes test
   assertions and incident posture app-specific.
3. **No local health/readiness helper.** Apps can call `client.ping`, but there
   is no packaged `health` result that classifies config, socket reachability,
   auth failure, circuit state, and daemon build/version if available.
4. **No deterministic test helper layer.** Current unit tests use local fake
   sockets internally. App integrators need small helpers such as
   `stub_tbackend(status:)`, `assert_tbackend_fact`, and `capture_mirror_result`
   so shadow code is easy to test without a daemon.
5. **Payload sanitization is manual.** `only` / `except` work, but there is no
   named sanitizer object, denylist preset, or "stable value" helper that makes
   value content match the app's own `value_hash` exclusions.
6. **Background flush worker shape is not specified.** README tells apps to call
   `Mirror.mirror!` from an app-owned job for heavier paths, but there is no
   blessed worker contract, batch size, backoff, idempotency key, or metric
   vocabulary.
7. **Shadow-without-authority docs are spread across proof docs.** README has
   the right posture, but future Rails adopters need one adapter-specific recipe
   that combines triple guard, sampling, strict-off, loopback/private daemon,
   and "TBackend result is evidence only".

## 4. Recommended first implementation slice

First code card:

`LAB-ACTS-AS-TBACKEND-ADAPTER-DX-P4`

Goal: ship **health + policy + test helpers** before adding outbox persistence.

Why this first:

- It is low risk and does not force any business repo adoption.
- It makes later outbox work testable and operationally legible.
- It keeps dependencies light: no Sidekiq/ActiveJob dependency is needed yet.
- It gives Hub/Spark a clearer integration surface while preserving
  observe-only authority.

Proposed scope:

1. Add `ActsAsTbackend.health` / `Client#health` returning a soft result:
   config summary (host/port/strict/enabled/durability), circuit state,
   `ping` status, and a sanitized error.
2. Add `Config#failure_policy` with values:
   - `ignore` - current default, return soft result only;
   - `warn` - log soft failures;
   - `raise_in_test` - raise only when `ENV["RAILS_ENV"] == "test"` or
     explicit test flag is set;
   - `enqueue_retry` - reserved result status for future outbox worker, not
     implemented in P4.
3. Add `ActsAsTbackend::TestHelpers`:
   - fake client/connection with queued responses;
   - `assert_tbackend_fact(fact, store:, key:, value_includes:)`;
   - `capture_mirror_result(record, ...)`;
   - deterministic time/source-version helper.
4. Add `ActsAsTbackend::Sanitizer` as a plain Ruby helper:
   `Sanitizer.call(attributes, only:, except:, denylist:)`, used by `Mirror`
   internally without changing the public macro API.
5. Expand README with one "shadow without authority" recipe and one health
   check snippet.

Explicitly out of P4:

- no database outbox table;
- no Sidekiq/ActiveJob integration;
- no Hub/Spark/Avenlance code changes;
- no gem publishing.

## 5. Later DX slices

After P4, the next likely slices are:

| Slice | Purpose | Notes |
| --- | --- | --- |
| P5 outbox contract | Define a local mirror intent schema and a small flush interface. | Keep persistence app-owned first; adapter provides serializer and status mapping. |
| P6 background worker adapter | Optional ActiveJob/Sidekiq examples. | Avoid a hard Sidekiq dependency unless real adopters need it. |
| P7 release/publish | Publish `0.2.1` or later to RubyGems. | Requires clean tests, gem build, MFA, changelog, and GitHub tag. |
| P8 readback/parity helpers | Bounded `facts_by_seq` cursor helpers for shadow validation. | Must respect TBackend seq-visibility gate before production-like cursor use. |

## 6. Test plan

For P4:

- Unit: `Client#health` maps ping ok/down/circuit-open without raising.
- Unit: strict/token values are redacted from health errors.
- Unit: each `failure_policy` behavior is explicit; default remains soft.
- Unit: `TestHelpers` can stub `committed_acked`, `idempotent_replay`,
  `duplicate_fact_id_conflict`, `unavailable`, `timeout_unknown`, and
  `circuit_open`.
- Unit: sanitizer preserves `only` / `except` behavior and applies denylist.
- Regression: existing tests continue to pass.
- Packaging: `gem build acts-as-tbackend.gemspec` succeeds.
- Hygiene: `git diff --check` succeeds.

For future outbox work:

- No daemon available: business transaction can still commit and outbox intent
  remains retryable.
- Daemon recovers: flush writes deterministic facts and records replay as
  success.
- Conflict: surfaced as a durable mirror failure, not a retry loop.
- Timeout unknown: retry policy does not infer commit; deterministic id keeps
  a later retry safe.

## 7. Release / publish checklist

Before publishing any version:

1. Confirm `lib/acts_as_tbackend/version.rb` and gemspec metadata.
2. Run:
   ```bash
   ruby -Ilib:test -e 'Dir["test/*_test.rb"].each { |f| require File.expand_path(f) }'
   gem build acts-as-tbackend.gemspec
   ```
3. Inspect packaged files: current gemspec includes `lib/**/*.rb` and
   `README.md`; add docs only if the published gem should carry them.
4. Verify RubyGems remote state:
   ```bash
   gem search '^acts-as-tbackend$' --remote --all
   ```
5. Ensure `allowed_push_host` is still `https://rubygems.org` and MFA is ready.
6. Tag the GitHub repo after a successful publish.
7. Do not point Hub/Spark at the gem as authority. Adoption remains a separate
   product/release gate.

## 8. Acceptance for P4

`LAB-ACTS-AS-TBACKEND-ADAPTER-DX-P4` should require:

- Health helper implemented and documented.
- Failure policy implemented with tests and default behavior unchanged.
- Test helpers implemented without requiring a live daemon.
- Sanitizer helper implemented without broad ActiveSupport dependency.
- README updated with shadow-without-authority recipe.
- Existing Minitest suite passes.
- `gem build acts-as-tbackend.gemspec` passes.
- No Hub/Spark/Avenlance code changes.
