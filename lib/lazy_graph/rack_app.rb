# frozen_string_literal: true

require 'rack'

module LazyGraph
  class RackApp
    ALLOWED_VALUES_VALIDATE = [true, false, nil, 'input', 'context'].to_set.freeze
    ALLOWED_VALUES_DEBUG = [true, false, nil].to_set.freeze

    attr_reader :routes

    def initialize(routes: {})
      @routes = routes.transform_keys(&:to_sym).compare_by_identity
    end

    def call(env)
      env[:X_REQUEST_TIME_START] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      request = Rack::Request.new(env)

      return routes!(request) if (request.path == '/routes' || request.path == '/') && request.get?
      return health!(request) if request.path == '/health' && request.get?
      return not_found!(request) unless (graph_module = @routes[request.path.to_sym])
      return success!(request, graph_module.usage) if request.get?
      return not_found!("#{request.request_method} #{request.path}") unless request.post?

      query_lazy_graph!(request, graph_module)
    end

    def query_lazy_graph!(request, graph_module)
      body = begin
        JSON.parse(request.body.read, symbolize_names: true)
      rescue JSON::ParserError => e
        return not_acceptable!(request, 'Invalid JSON', e.message)
      end
      context, modules, validate, debug, query = body.values_at(:context, :modules, :validate, :debug, :query)
      unless context.is_a?(Hash) && !context.empty?
        return not_acceptable!(request, "Invalid 'context' Parameter", 'Should be a non-empty object.')
      end

      unless (modules.is_a?(Hash) && !modules.empty?) || modules.is_a?(String) || (modules.is_a?(Array) && modules.all? do |m|
        m.is_a?(String)
      end)
        return not_acceptable!(request, "Invalid 'modules' Parameter",
                               'Should be a string, string-array or non-empty object.')
      end

      modules = Array(modules).map { |m| [m, {}] }.to_h unless modules.is_a?(Hash)

      unless ALLOWED_VALUES_VALIDATE.include?(validate)
        return not_acceptable!(
          request, "Invalid 'validate' Parameter", "Should be nil, bool, or one of 'input', 'context'"
        )
      end

      unless ALLOWED_VALUES_DEBUG.include?(debug) || debug.is_a?(String)
        return not_acceptable!(request, "Invalid 'debug' Parameter", 'Should be nil or bool')
      end

      debug = Regexp.new(Regexp.escape(debug)) if debug.is_a?(String) && debug != 'exceptions'

      unless query.nil? || query.is_a?(String) || (query.is_a?(Array) && query.all? do |q|
        q.is_a?(String)
      end)
        return not_acceptable!(request, "Invalid 'query' Parameter", 'Should be nil, array or string array')
      end

      begin
        result = graph_module.eval!(
          modules: modules,
          context: context,
          validate: validate.nil? ? true : validate,
          debug: if !debug.nil?
                   debug
                 else
                   LazyGraph::Environment.development? ? 'exceptions' : debug
                 end,
          query: query
        )
        return not_acceptable!(request, result[:message], result[:detail]) if result[:type] == :error

        success!(request, result)
      rescue AbortError, ValidationError => e
        LazyGraph.logger.error(e.message)
        LazyGraph.logger.error(e.backtrace.join("\n"))
        error!(request, 400, 'Bad Request', e.message)
      rescue StandardError => e
        LazyGraph.logger.error(e.message)
        LazyGraph.logger.error(e.backtrace.join("\n"))

        error!(request, 500, 'Internal Server Error', e.message)
      end
    end

    def routes!(request)
      success!(request, @routes.keys.map { |k, _v| { route: k.to_s, methods: %i[GET POST] } })
    end

    def health!(request)
      success!(request, { status: 'ok' })
    end

    def not_acceptable!(request, message, details = '')
      error!(request, 406, message, details)
    end

    def not_found!(request, details = '')
      error!(request, 404, 'Not Found', details)
    end

    def request_ms(request)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - request.env[:X_REQUEST_TIME_START]) * 1000.0).round(3)
    end

    def success!(request, result, status: 200)
      req_ms = request_ms(request)

      LazyGraph.logger.info(
        Logger.build_color_string do
          "#{bold(request.request_method)}: #{dim(request.path)} => #{green(status)} #{light_gray("#{req_ms}ms")}"
        end
      )

      [status, { 'content-type' => 'application/json' }, [JSON.fast_generate(result)]]
    end

    def error!(request, status, message, details = '')
      req_ms = request_ms(request)

      LazyGraph.logger.error(
        Logger.build_color_string do
          "#{bold(request.request_method)}: #{dim(request.path)} => #{status.to_i >= 500 ? red(status) : orange(status)} #{light_gray("#{req_ms}ms")}"
        end
      )

      [status, { 'content-type' => 'application/json' }, [JSON.fast_generate({ 'error': message, 'details': details })]]
    end
  end
end
