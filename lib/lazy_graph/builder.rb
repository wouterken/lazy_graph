# frozen_string_literal: true

# Subclass LazyGraph::Builder to create new builder classes
# which can be used to easily build a rule-set to be used as a LazyGraph.
#
require_relative 'builder/dsl'

module LazyGraph
  class Builder
    # Cache up to a fixed number of graphs, context and queries
    BUILD_CACHE_CONFIG = {
      # Store up to 1000 graphs
      graph: { size: ENV.fetch('LAZY_GRAPH_GRAPH_CACHE_MAX_ENTRIES', 1000).to_i, cache: {} },
      # Store up to 5000 configs
      context: { size: ENV.fetch('LAZY_GRAPH_CONTEXT_CACHE_MAX_ENTRIES', 5000).to_i, cache: {} },
      # Store up to 5000 queries
      query: { size: ENV.fetch('LAZY_GRAPH_QUERY_CACHE_MAX_ENTRIES', 5000).to_i, cache: {} }
    }.compare_by_identity.freeze

    include DSL
    # This class is responsible for piece-wise building of rules,
    # as a combined schema definition.
    attr_accessor :schema

    def initialize(schema: { type: 'object', properties: {} }) = @schema = schema
    def context(value, debug: false, validate: true) = build!(debug: debug, validate: validate).context(value)

    def eval!(context, *value, debug: false,
              validate: true) = context(context, validate: validate, debug: debug).get(*value)
    alias feed context

    def build!(debug: false, validate: true) = @schema.to_lazy_graph(
      debug: debug,
      validate: validate,
      helpers: self.class.helper_modules,
      namespace: self.class
    )

    def self.rules_module(name, schema = { type: 'object', properties: {} }, &blk)
      rules_modules[:properties][name.to_sym] = { type: :object, properties: schema }
      module_body_func_name = :"_#{name}"
      define_method(module_body_func_name, &blk)
      define_method(name) do |**args, &inner_blk|
        @path = @path.nil? ? "#{name}" : "#{@path}+#{name}" unless @path.to_s.include?(name.to_s)
        send(module_body_func_name, **args, &inner_blk)
        self
      end
    end

    # Helper for defining a new entity in the schema (just a shorthand for defining a new method for now)
    def self.entity(name, &blk)
      module_body_func_name = :"_#{name}"
      define_method(module_body_func_name, &blk)
      define_method(name) do |**args, &inner_blk|
        send(module_body_func_name, **args)
        inner_blk&.call
        self
      end
    end

    class << self
      attr_reader :helper_modules
    end

    def self.register_helper_modules(*mods) = mods.each(&method(:register_helper_module))

    def self.register_helper_module(mod)
      (@helper_modules ||= []) << mod
    end

    def self.clear_rules_modules!
      @rules_modules = nil
    end

    def self.clear_helper_modules!
      @helper_modules = nil
    end

    def self.clear_caches!
      clear_rules_modules!
      clear_helper_modules!
      BUILD_CACHE_CONFIG.each_value { |v| v[:cache].clear }
    end

    def self.rules_modules
      @rules_modules ||= {
        type: :object,
        properties: {},
        additionalProperties: false
      }
    end

    def self.usage
      {
        modules_options: rules_modules[:properties].map do |k, v|
          {
            name: k.to_s,
            properties: v[:properties],
            required: v[:required]
          }
        end,
        context_sample_schema: rules_modules[:properties].keys.reduce(new) do |acc, (k, _v)|
          acc.send(k, **{})
        end.schema
      }
    end

    def self.eval!(modules:, context:, query:, debug: false, validate: true)
      graph = cache_as(:graph, [modules, debug, validate]) do
        invalid_modules = modules.reject { |k, _v| rules_modules[:properties].key?(k.to_sym) }
        return format_error_response('Invalid Modules', invalid_modules.keys.join(',')) unless invalid_modules.empty?

        error = validate_modules(modules)

        return format_error_response('Invalid Module Option', error) unless error.empty?

        builder = build_modules(modules)
        return builder if builder.is_a?(Hash)

        builder.build!(debug: debug, validate: validate)
      end

      context_result = cache_as(:context, [graph, context]) do
        build_context(graph, context)
      end

      return context_result if context_result.is_a?(Hash) && context_result[:type].equal?(:error)

      cache_as(:query, [context_result, query]) do
        HashUtils.strip_missing(
          {
            type: :success,
            result: context_result.resolve(*(query || ''))
          }
        )
      end
    rescue SystemStackError => e
      LazyGraph.logger.error(e.message)
      LazyGraph.logger.error(e.backtrace.join("\n"))
      {
        type: :error,
        message: 'Recursive Query Detected',
        detail: "Problem query path: #{query}"
      }
    end

    def self.cache_as(type, key)
      cache, max_size = BUILD_CACHE_CONFIG[type].values_at(:cache, :size)
      key = key.hash
      cache[key] = cache[key] ? cache.delete(key) : yield
    ensure
      cache.delete(cache.keys.first) while cache.size > max_size
    end

    def to_str
      "LazyGraph(modules=#{@path})"
    end

    private_class_method def self.method_missing(method_name, *args, &block) = new.send(method_name, *args, &block)
    private_class_method def self.respond_to_missing?(_, _ = false) = true
    private_class_method def self.validate_modules(input_options)
      JSON::Validator.validate!(rules_modules, input_options)
      ''
    rescue StandardError => e
      e.message
    end

    private_class_method def self.format_error_response(message, detail)
      {
        type: :error,
        message: message,
        **(detail.to_s =~ /Schema: / ? { location: detail[/^Schema: #(.*)$/, 1] } : {}),
        detail: detail.to_s
      }
    end

    private_class_method def self.build_modules(input_options)
      input_options.reduce(new.additional_properties(false)) do |acc, (k, v)|
        acc.send(k, **v.to_h.transform_keys(&:to_sym))
      end
    rescue ArgumentError => e
      LazyGraph.logger.error(e.message)
      LazyGraph.logger.error(e.backtrace.join("\n"))
      format_error_response('Invalid Module Argument', e.message)
    end

    private_class_method def self.build_context(graph, context)
      graph.context(context)
    rescue StandardError => e
      if graph.debug?
        LazyGraph.logger.error(e.message)
        LazyGraph.logger.error(e.backtrace.join("\n"))
      end
      format_error_response('Invalid Context Input', e.message)
    end
  end
end
