require File.join File.expand_path('lib', __dir__), 'matrix_releasetracker/version'

Gem::Specification.new do |spec|
  spec.name          = 'matrix_releasetracker'
  spec.version       = MatrixReleasetracker::VERSION
  spec.authors       = ['Alexander Olofsson']
  spec.email         = ['ace@haxalot.com']

  spec.summary       = %q{Write a short summary, because RubyGems requires one.}
  spec.description   = %q{Write a longer description or delete this line.}
  spec.homepage      = 'https://github.com/ananace/ruby-matrix-releasetracker'
  spec.license       = 'MIT'

  spec.files         = Dir.glob('{bin,lib}/**/*') + %w[LICENSE.txt README.md]
  spec.bindir        = 'bin'
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  spec.add_dependency 'faraday-http-cache'
  spec.add_dependency 'gitlab'
  spec.add_dependency 'kramdown'
  spec.add_dependency 'logging', '~> 2'
  spec.add_dependency 'matrix_sdk', '~> 1'
  spec.add_dependency 'octokit', '~> 4.0'

  spec.add_development_dependency 'bundler', '~> 1.16'
  spec.add_development_dependency 'minitest', '~> 5.0'
  spec.add_development_dependency 'rake', '~> 10.0'
end
