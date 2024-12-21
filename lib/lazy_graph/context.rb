# frozen_string_literal: true

module LazyGraph
  # Context class is responsible for managing ruleset and input data,
  # allowing querying and dynamic method calls to access input fields.
  class Context
    attr_accessor :ruleset, :input

    def initialize(graph, input)
      input = HashUtils.deep_dup(input, symbolize: true)
      graph.validate!(input) if [true, 'input'].include?(graph.validate)
      @graph = graph
      @input = input
      @graph.root_node.properties.each_key do |key|
        define_singleton_method(key) { get(key) }
      end
    end

    def get_json(path)
      HashUtils.strip_missing(get(path))
    end

    def get(path)
      result = resolve(path)
      raise result[:error] if result[:err]

      result[:output]
    end

    def debug(path)
      result = resolve(path)
      raise result[:error] if result[:err]

      result[:debug_trace]
    end

    def resolve(path)
      @input = @graph.root_node.fetch_item({ input: @input }, :input, nil)

      query = PathParser.parse(path, strip_root: true)
      stack = StackPointer.new(nil, @input, 0, 0, :'$', nil)
      stack.root = stack

      result = @graph.root_node.resolve(query, stack)

      @graph.root_node.clear_visits!
      if @graph.debug?
        debug_trace = stack.frame[:DEBUG]
        stack.frame[:DEBUG] = nil
      end
      {
        output: result,
        debug_trace: debug_trace
      }
    rescue AbortError, ValidationError => e
      {
        output: nil, err: e.message, status: :abort, error: e
      }
    rescue StandardError => e
      if @graph.debug?
        LazyGraph.logger.error(e.message)
        LazyGraph.logger.error(e.backtrace.join("\n"))
      end
      {
        output: nil, err: e.message, backtrace: e.backtrace, error: e
      }
    end

    def pretty_print(q)
      # Start the custom pretty print
      q.group(1, '<LazyGraph::Context ', '>') do
        q.group do
          q.text 'graph='
          q.pp(@graph)
        end
        q.group do
          q.text 'input='
          q.pp(@input)
        end
      end
    end

    def [](*parts)
      get(parts.map { |p| p.is_a?(Integer) ? "[#{p}]" : p.to_s }.join('.').gsub('.[', '['))
    end
  end
end
