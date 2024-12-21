require 'lazy_graph'
require 'minitest/reporters'
Bundler.require(:default, :test)
Minitest::Reporters.use! Minitest::Reporters::SpecReporter.new
