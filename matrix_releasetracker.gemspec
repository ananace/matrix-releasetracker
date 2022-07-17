# frozen_string_literal: true

require File.join File.expand_path('lib', __dir__), 'matrix_releasetracker/version'

Gem::Specification.new do |spec|
  spec.name          = 'matrix_releasetracker'
  spec.version       = MatrixReleasetracker::VERSION
  spec.authors       = ['Alexander Olofsson']
  spec.email         = ['ace@haxalot.com']

  spec.summary       = 'Release tracker that posts updates into Matrix rooms'
  spec.description   = spec.summary
  spec.homepage      = 'https://github.com/ananace/ruby-matrix-releasetracker'
  spec.license       = 'MIT'

  spec.files         = Dir.glob('{bin,lib}/**/*') + %w[LICENSE.txt README.md]
  spec.bindir        = 'bin'
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.required_ruby_version = '>= 2.7.0'

  spec.add_dependency 'faraday-http-cache'
  # spec.add_dependency 'gitlab', '~> 4'
  spec.add_dependency 'kramdown'
  spec.add_dependency 'logging', '~> 2'
  spec.add_dependency 'matrix_sdk', '~> 2'
  spec.add_dependency 'octokit', '~> 5'
  spec.add_dependency 'sequel', '~> 5.58'

  # TODO: Gem groups
  spec.add_dependency 'pg', '~> 1.4'      # PostgreSQL
  spec.add_dependency 'sqlite3', '~> 1.4' # SQLite

  spec.add_development_dependency 'bundler', '~> 2'
  spec.add_development_dependency 'minitest', '~> 5'
  spec.add_development_dependency 'rake', '~> 13'
end
