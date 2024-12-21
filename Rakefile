# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'minitest/test_task'
require 'debug'

Minitest::TestTask.create(:test) do |t|
  t.libs << 'test'
  t.libs << 'lib'
  t.warning = false
  t.test_globs = ['test/**/*_test.rb']
  t.test_prelude = 'require "helpers/test_helper.rb"'
end

task default: :test
