# Releasing acts-as-tbackend

`acts-as-tbackend` is public as part of `igniter-lab` and should now live as a
small standalone public GitHub repository:

```text
https://github.com/alexander-s-f/acts-as-tbackend
```

The Forgejo repository may remain an internal read-only mirror, but it is not the
canonical source and not the package authority. SparkCRM and other apps should
consume a normal versioned gem.

## Repository flow

From `igniter-lab`, publish the subtree mirror:

```bash
bin/push-acts-as-tbackend-mirror
```

For the public GitHub repo, either point the helper at a GitHub remote or push the
same subtree split branch to GitHub:

```bash
git remote add acts-as-tbackend-github https://github.com/alexander-s-f/acts-as-tbackend.git
bin/push-acts-as-tbackend-github-mirror
```

Keep the GitHub README as the team-facing entrypoint. If Forgejo is retained,
make its README say "canonical: GitHub" to avoid dependency-source confusion.

## Publish a RubyGem

The gemspec uses:

```text
allowed_push_host = https://rubygems.org
homepage/source   = https://github.com/alexander-s-f/acts-as-tbackend
```

Release:

```bash
cd runtime/acts-as-tbackend
# 1. bump lib/acts_as_tbackend/version.rb (SemVer) if this is a new release
# 2. sanity
ruby -Ilib:test -e 'Dir["test/*_test.rb"].each { |f| require File.expand_path(f) }'
# 3. build + push
gem build acts-as-tbackend.gemspec
gem push acts-as-tbackend-*.gem
rm -f acts-as-tbackend-*.gem
```

Versions are immutable. Re-pushing the same version fails; bump `VERSION` first.

## Consume from SparkCRM

Once published:

```ruby
gem "acts-as-tbackend", "~> 0.2"
```

This is prod-safe: a normal versioned gem, no sibling checkout, no VPN-bound
package registry, and no private token for ordinary `bundle install`.

The P6 LeadSignal shadow canary remains disabled by default and still guards on:

```text
ActsAsTbackend.enabled? + canary flag + sample gate
```

## Notes

- Do not publish to a private Forgejo package registry for app dependencies unless
  there is a separate operational reason. It adds VPN/token friction for CI and
  developers.
- If GitHub Packages is ever used instead of RubyGems.org, update
  `allowed_push_host`, this release doc, and SparkCRM's `Gemfile` source block in
  one commit.
