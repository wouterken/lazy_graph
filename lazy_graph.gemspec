# frozen_string_literal: true

require_relative 'lib/lazy_graph/version'

Gem::Specification.new do |spec|
  spec.name = 'lazy_graph'
  spec.version = LazyGraph::VERSION
  spec.authors = ['Wouter Coppieters']
  spec.email = ['wc@pico.net.nz']

  spec.summary = 'JSON Driven, Stateless Rules Engine'
  spec.description = 'JSON Driven, Stateless Rules Engine for JIT and efficient evaluation of complex rules and computation graphs.'
  spec.homepage = 'https://github.com/wouterken/lazy_graph'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.0.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/wouterken/lazy_graph'

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git appveyor Gemfile])
    end
  end
  spec.bindir = 'exe'
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  spec.add_dependency 'json-schema'
  spec.add_dependency 'logger'
  spec.add_dependency 'prism'

  spec.add_development_dependency 'benchmark-ips'
  spec.add_development_dependency 'debug', '~> 1.0'
  spec.add_development_dependency 'fiddle'
  spec.add_development_dependency 'listen'
  spec.add_development_dependency 'memory_profiler'
  spec.add_development_dependency 'observer'
  spec.add_development_dependency 'ostruct'
  spec.add_development_dependency 'rack'
  spec.add_development_dependency 'rake', '~> 13.0'
  spec.add_development_dependency 'rdoc'
  spec.add_development_dependency 'rubocop'
  spec.add_development_dependency 'solargraph'
  spec.add_development_dependency 'vernier'
end
