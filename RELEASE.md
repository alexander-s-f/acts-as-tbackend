# Releasing acts-as-tbackend — Forgejo private registry option

`acts-as-tbackend` is internal-only. This document describes the current **Forgejo
RubyGems package registry** option (owner `Igniter` on `git.int.avenlance.com`),
not rubygems.org. The gemspec's `allowed_push_host` blocks an accidental public push.

If GitHub becomes the canonical repository/package host, update the gemspec
`allowed_push_host`, homepage/source URIs, and the SparkCRM bundler source before
publishing.

Registry URL:

```text
https://git.int.avenlance.com/api/packages/Igniter/rubygems
```

## One-time: auth

Create a Forgejo **access token** with `package:write` (publish) / `package:read` (consume)
scope, then add it to `~/.gem/credentials` (mode 0600):

```yaml
---
https://git.int.avenlance.com/api/packages/Igniter/rubygems: Bearer <FORGEJO_TOKEN>
```

(Never commit the token. `chmod 600 ~/.gem/credentials`.)

## Publish a version

```bash
cd runtime/acts-as-tbackend
# 1. bump lib/acts_as_tbackend/version.rb (SemVer) if this is a new release
# 2. sanity
ruby -Ilib:test -e 'Dir["test/*_test.rb"].each { |f| require File.expand_path(f) }'   # 12/0 green
# 3. build + push (allowed_push_host guards the target)
gem build acts-as-tbackend.gemspec
gem push --host https://git.int.avenlance.com/api/packages/Igniter/rubygems acts-as-tbackend-*.gem
rm -f acts-as-tbackend-*.gem
```

Versions are immutable — re-pushing the same version fails; bump `VERSION` first.

## Consume from SparkCRM if Forgejo stays the package host (P6 canary + beyond)

Configure bundler auth for the private source (once, per machine/CI):

```bash
bundle config set --global https://git.int.avenlance.com/api/packages/Igniter/rubygems <FORGEJO_TOKEN>
```

Then in the SparkCRM `Gemfile`:

```ruby
source "https://git.int.avenlance.com/api/packages/Igniter/rubygems" do
  gem "acts-as-tbackend", "~> 0.2"
end
```

This is prod-safe: a normal versioned gem from a private source, no sibling-path checkout
dependency. The P6 LeadSignal shadow canary stays disabled by default and guards on
`ActsAsTbackend.enabled?` + the canary flag regardless.

## Notes

- CI / other developers need `package:read` auth configured to `bundle install`; document the
  token in the team secret store, not here.
- First publish also implicitly creates the `Igniter/acts-as-tbackend` package in Forgejo.
