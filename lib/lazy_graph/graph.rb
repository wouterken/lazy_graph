# frozen_string_literal: true

require 'json-schema'

module LazyGraph
  # Represents a lazy graph structure based on JSON schema
  VALIDATION_CACHE = {}.compare_by_identity
  METASCHEMA = JSON.load_file(File.join(__dir__, 'lazy-graph.json'))

  class Graph
    attr_reader :json_schema, :root_node, :validate

    def context(input) = Context.new(self, input)
    def debug? = !!@debug
    alias input context
    alias feed context

    def initialize(input_schema, debug: false, validate: true, helpers: nil, namespace: nil)
      @json_schema = HashUtils.deep_dup(input_schema, symbolize: true, signature: signature = [0]).merge(type: :object)
      @debug = debug
      @validate = validate
      @helpers = helpers

      VALIDATION_CACHE[signature[0]] ||= validate!(@json_schema, METASCHEMA) if [true, 'schema'].include?(validate)

      if @json_schema[:type].to_sym != :object || @json_schema[:properties].nil?
        raise ArgumentError, 'Root schema must be a non-empty object'
      end

      @root_node = build_node(@json_schema, namespace: namespace)
      @root_node.build_derived_inputs!
    end

    def build_node(schema, path = :'$', name = :root, parent = nil, namespace: nil)
      schema[:type] = schema[:type].to_sym
      node = \
        case schema[:type]
        when :object then ObjectNode
        when :array then ArrayNode
        else Node
        end.new(name, path, schema, parent, debug: @debug, helpers: @helpers, namespace: namespace)

      if node.type.equal?(:object)
        node.children = \
          {
            properties: schema.fetch(:properties, {}).map do |key, value|
              [key, build_node(value, :"#{path}.#{key}", key, node)]
            end.to_h.compare_by_identity,
            pattern_properties: schema.fetch(:patternProperties, {}).map do |key, value|
              [Regexp.new(key.to_s), build_node(value, :"#{path}.#{key}", :'<property>', node)]
            end
          }
      elsif node.type.equal?(:array)
        node.children = build_node(schema.fetch(:items, {}), :"#{path}[]", :items, node)
      end
      node
    end

    def validate!(input, schema = @json_schema)
      JSON::Validator.validate!(schema, input)
    rescue JSON::Schema::ValidationError => e
      raise ValidationError, "Input validation failed: #{e.message}", cause: e
    end

    def pretty_print(q)
      # Start the custom pretty print
      q.group(1, '<LazyGraph::Graph ', '>') do
        q.group do
          q.text 'props='
          q.text root_node.children[:properties].keys
        end
      end
    end
  end

  Hash.define_method(:to_lazy_graph, ->(**opts) { LazyGraph::Graph.new(self, **opts) })
  Hash.define_method(:to_graph_ctx, ->(input, **opts) { to_lazy_graph(**opts).context(input) })
  Hash.define_method(:eval_graph, ->(input, *query, **opts) { to_graph_ctx(input, **opts)[*query] })
end
