# frozen_string_literal: true

module LazyGraph
  class CLI
    # A builder group rack-app can be exposed via a simple rack based HTTP server
    # with routes corresponding to each builder class deeply nested
    # withhin the builder group module.
    def self.invoke!(rack_app)
      require 'etc'
      require 'optparse'
      require 'rack'

      options = {
        port: 9292,
        workers: (Environment.development? ? 1 : Etc.nprocessors)
      }

      OptionParser.new do |opts|
        opts.banner = "Usage: #{$0} [options]"

        opts.on('-p PORT', '--port PORT', Integer, "Set the port (default: #{options[:port]})") do |p|
          options[:port] = p
        end

        opts.on('-w WORKERS', '--workers WORKERS', Integer,
                "Set the number of workers (default: #{options[:workers]})") do |w|
          options[:workers] = w
        end

        opts.on('-h', '--help', 'Print this help') do
          puts opts
          exit
        end
      end.parse!
      # A builder group can be exposed as a simple rack based HTTP server
      # with routes corresponding to each builder class deeply nested
      # withhin the builder group module.

      RackServer.new(
        Rack::Builder.new do
          use Rack::Lint if Environment.development?
          run rack_app
        end
      ).start(port: options[:port], workers: options[:workers])
    end
  end
end
