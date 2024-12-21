require 'logger'
require_relative 'environment'

module LazyGraph
  class << self
    attr_accessor :logger
  end

  module Logger
    COLORIZED_LOGS = !ENV['DISABLED_COLORIZED_LOGS'] && ENV.fetch('RACK_ENV', 'development') == 'development'

    module_function

    class << self
      attr_accessor :color_enabled, :structured
    end

    def structured
      return @structured if defined?(@structured)
      @structured = !LazyGraph::Environment.development?
    end

    def default_logger
      logger = ::Logger.new($stdout)
      self.color_enabled ||= Logger::COLORIZED_LOGS
      if self.color_enabled
        logger.formatter = proc do |severity, datetime, progname, message|
          light_gray_timestamp = "\e[90m[##{Process.pid}] #{datetime.strftime('%Y-%m-%dT%H:%M:%S.%6N')}\e[0m" # Light gray timestamp
          "#{light_gray_timestamp} \e[1m#{severity}\e[0m #{progname}: #{message}\n"
        end
      elsif self.structured
        logger.formatter = proc do |severity, datetime, progname, message|
          "#{{severity:, datetime:, progname:, **(message.is_a?(Hash) ? message : {message: }) }.to_json}\n"
        end
      else
        logger.formatter = proc do |severity, datetime, progname, message|
          "[##{Process.pid}] #{datetime.strftime('%Y-%m-%dT%H:%M:%S.%6N')} #{severity} #{progname}: #{message}\n"
        end
      end
      logger
    end

    def build_color_string(&blk)
      return unless block_given?

      instance_eval(&blk)
    end

    def colorize(text, color_code)
      @color_enabled ? "\e[#{color_code}m#{text}\e[0m" : text
    end

    def green(text)
      colorize(text, 32) # Green for success
    end

    def red(text)
      colorize(text, 31) # Red for errors
    end

    def yellow(text)
      colorize(text, 33) # Yellow for warnings or debug
    end

    def blue(text)
      colorize(text, 34) # Blue for info
    end

    def light_gray(text)
      colorize(text, 90) # Light gray for faded text
    end

    def orange(text)
      colorize(text, '38;5;214')
    end

    def bold(text)
      colorize(text, 1) # Bold text
    end

    def dim(text)
      colorize(text, 2) # Italic text
    end
  end

  self.logger = Logger.default_logger
end
