# frozen_string_literal: true

require 'bigdecimal/util'
require 'json'

module LazyGraph
  require_relative 'node/derived_rules'
  require_relative 'node/array_node'
  require_relative 'node/object_node'
  require_relative 'node/node_properties'

  DIGIT_REGEXP = /^-?\d+$/
  SAFE_TOKEN_REGEXP = /^[A-Za-z][A-Za-z0-9]*$/
  PROPERTY_CLASSES = {}
  UNIQUE_NAME_COUNTER = Hash.new(0)

  def self.fetch_property_class(name, members, namespace: nil)
    namespace ||= LazyGraph
    PROPERTY_CLASSES[members] ||= begin
      name = name.to_s.capitalize.gsub(/(\.|_)([a-zA-Z])/) do |m|
        m[1].upcase
      end.gsub(/[^a-zA-Z]/, '').then { |n| n.length > 0 ? n : 'NodeProps' }
      index = UNIQUE_NAME_COUNTER[[name, namespace]] += 1
      full_name = "#{name}#{index > 1 ? index : ''}"
      namespace.const_set(full_name, NodeProperties.build(**members))
    end
  end

  # Class: Node
  # Represents A single Node within our LazyGraph structure
  # A node is a logical position with a graph structure.
  # The node might capture knowledge about how to derived values at its position
  # if a value is not provided.
  # This can be in the form of a default value or a derivation rule.
  #
  # This class is heavily optimized to resolve values in a graph structure
  # with as little overhead as possible. (Note heavy use of ivars,
  # and minimal method calls in the recursive resolve method).
  #
  # Nodes support (non-circular) recursive resolution of values, i.e.
  # if a node depends on the output of several other nodes in the graph,
  # it will resolve those nodes first before resolving itself.
  #
  # Node resolution maintains a full stack, so that values can be resolved relative to the position
  # of the node itself.
  #

  class Node
    include DerivedRules
    attr_accessor :name, :path, :type, :derived, :depth, :parent, :root, :invisible
    attr_accessor :children
    attr_reader :is_object, :namespace

    def simple? = @simple

    def initialize(name, path, node, parent, debug: false, helpers: nil, namespace: nil)
      @name = name
      @path = path
      @parent = parent
      @debug = debug
      @depth = parent ? parent.depth + 1 : 0
      @root = parent ? parent.root : self
      @rule = node[:rule]
      @rule_location = node[:rule_location]
      @type = node[:type]
      @validate_presence = node[:validate_presence]
      @helpers = helpers
      @invisible = debug.eql?(true) ? false : node[:invisible]
      @visited = {}.compare_by_identity
      @namespace = namespace

      instance_variable_set("@is_#{@type}", true)
      define_singleton_method(:cast, build_caster)
      define_singleton_method(:trace!, proc { |*| }) unless @debug

      define_missing_value_proc!

      @has_default = node.key?(:default)
      @default = @has_default ? cast(node[:default]) : MissingValue { @name }

      # Simple nodes are not a container type, and do not have rule or default
      @simple = !(%i[object array date time timestamp decimal].include?(@type) || node[:rule] || @has_default)
    end

    def build_derived_inputs!
      build_derived_inputs(@rule, @helpers) if @rule
      return unless @children
      return @children.build_derived_inputs! if @children.is_a?(Node)

      @children[:properties]&.each_value(&:build_derived_inputs!)
      @children[:pattern_properties]&.each do |(_, node)|
        node.build_derived_inputs!
      end
    end

    def define_missing_value_proc!
      define_singleton_method(
        :MissingValue,
        @debug ? ->(&blk) { MissingValue.new(blk&.call || absolute_path) } : -> { MissingValue::BLANK }
      )
    end

    def fetch_and_resolve(path, input, segment, stack_memory, preserve_keys = nil)
      item = fetch_item(input, segment, stack_memory)
      unless @simple || item.is_a?(MissingValue)
        item = resolve(
          path,
          stack_memory.push(item, segment)
        )
      end

      item = cast(item) if @simple

      preserve_keys ? preserve_keys[segment] = item : item
    end

    def build_caster
      if @is_decimal
        ->(value) { value.is_a?(BigDecimal) ? value : value.to_d }
      elsif @is_date
        lambda { |value|
          if value.is_a?(String)
            Date.parse(value)
          else
            value.is_a?(Symbol) ? Date.parse(value.to_s) : value
          end
        }
      elsif @is_boolean
        lambda do |value|
          if value.is_a?(TrueClass) || value.is_a?(FalseClass)
            value
          else
            value.is_a?(MissingValue) ? false : !!value
          end
        end
      elsif @is_timestamp
        lambda do |value|
          case value
          when String
            DateTime.parse(value).to_time
          when Numeric
            Time.at(value)
          else
            value
          end
        end
      elsif @is_string
        lambda(&:to_s)
      else
        ->(value) { value }
      end
    end

    def clear_visits!
      @visited.clear
      @resolution_stack&.clear
      @path_cache&.clear
      @resolvers&.clear

      return unless @children
      return @children.clear_visits! if @children.is_a?(Node)

      @children[:properties]&.each_value(&:clear_visits!)
      @children[:pattern_properties]&.each do |(_, node)|
        node.clear_visits!
      end
    end

    def resolve(
      path,
      stack_memory,
      should_recycle = stack_memory,
      **
    )
      path.empty? ? stack_memory.frame : MissingValue()
    ensure
      should_recycle&.recycle!
    end

    def lazy_init_node!(input, key)
      case input
      when Hash
        node = Node.new(key, "#{path}.#{key}", { type: :object }, self)
        node.children = { properties: {}, pattern_properties: [] }
        node
      when Array
        node = Node.new(key, :"#{path}.#{key}[]", { type: :array }, self)
        child_type = \
          case input.first
          when Hash then :object
          when Array then :array
          end
        node.children = Node.new(:items, :"#{path}.#{key}[].items", { type: child_type }, node)
        node.children.children = { properties: {}, pattern_properties: [] } if child_type.equal? :object
        node
      else
        Node.new(key, :"#{path}.#{key}", {}, self)
      end
    end

    def absolute_path
      @absolute_path ||= begin
        next_node = self
        path = []
        while next_node
          path << next_node.name
          next_node = next_node.parent
        end
        path.reverse.join('.')
      end
    end

    def ancestors
      @ancestors ||= [self, *(@parent ? @parent.ancestors : [])]
    end

    def find_resolver_for(segment)
      segment.equal?(:'$') ? root : @parent&.find_resolver_for(segment)
    end

    def resolve_relative_input(stack_memory, path)
      input_frame_pointer = path.absolute? ? stack_memory.root : stack_memory.ptr_at(depth - 1)
      input_frame_pointer.recursion_depth += 1

      return cast(input_frame_pointer.frame[path.first_path_segment.part]) if @simple

      fetch_and_resolve(
        path.absolute? ? path.next.next : path.next, input_frame_pointer.frame, path.first_path_segment.part, input_frame_pointer
      )
    ensure
      input_frame_pointer.recursion_depth -= 1
    end

    def fetch_item(input, key, stack)
      return MissingValue { key } unless input

      has_value = \
        case input
        when Array then input.length > key && input[key]
        when Hash, Struct then input.key?(key) && !input[key].is_a?(MissingValue)
        end

      if has_value
        value = input[key]
        value = cast(value) if value || @is_boolean
        return input[key] = value
      end

      return input[key] = @default unless derived

      if stack.recursion_depth >= 8
        input_id = key.object_id >> 2 ^ input.object_id << 28
        if @resolution_stack.key?(input_id)
          trace!(stack, exception: 'Infinite Recursion Detected during dependency resolution') do
            { output: :"#{stack}.#{key}" }
          end
          return MissingValue { "Infinite Recursion in #{stack} => #{key}" }
        end
        @resolution_stack[input_id] = true
      end

      @copy_input ? copy_item!(input, key, stack, @inputs.first) : derive_item!(input, key, stack)
    ensure
      @resolution_stack.delete(input_id) if input_id
    end

    def copy_item!(input, key, stack, (path, resolver, _i, segments))
      missing_value = resolver ? nil : MissingValue { key }
      if resolver && segments
        parts = path.parts.dup
        parts_identity = path.identity
        segments.each do |index, resolver|
          break missing_value = MissingValue { key } unless resolver

          part = resolver.resolve_relative_input(stack, parts[index].options.first)
          if part.is_a?(MissingValue)
            raise_presence_validation_error!(stack, key, parts[index].options.first) if @validate_presence
            break missing_value = part
          end

          part_sym = part.to_s.to_sym
          parts_identity ^= part_sym.object_id << index
          parts[index] = @path_cache[part_sym] ||= PathParser::PathPart.new(part: part_sym)
        end
        path = @path_cache[parts_identity] ||= PathParser::Path.new(parts: parts) unless missing_value
      end

      result = missing_value || cast(resolver.resolve_relative_input(stack, path))

      if result.nil? || result.is_a?(MissingValue)
        raise_presence_validation_error!(stack, key, path) if @validate_presence
        input[key] = MissingValue { key }
      else
        input[key] = result
      end
    end

    def derive_item!(input, key, stack)
      @inputs.each do |path, resolver, i, segments|
        if segments
          missing_value = nil
          parts = path.parts.dup
          parts_identity = path.identity
          segments.each do |index, resolver|
            break missing_value = MissingValue { key } unless resolver

            part = resolver.resolve_relative_input(stack, parts[index].options.first)
            if part.is_a?(MissingValue)
              raise_presence_validation_error!(stack, key, parts[index].options.first) if @validate_presence
              break missing_value = part
            end

            part_sym = part.to_s.to_sym
            parts_identity ^= part_sym.object_id << (index * 8)
            parts[index] = @path_cache[part_sym] ||= PathParser::PathPart.new(part: part_sym)
          end
          path = @path_cache[parts_identity] ||= PathParser::Path.new(parts: parts) unless missing_value
        end
        result = begin
          missing_value || resolver.resolve_relative_input(stack, path)
        rescue AbortError, ValidationError => e
          raise e
        rescue StandardError => e
          ex = e
          LazyGraph.logger.error("Error in #{self.path}")
          LazyGraph.logger.error(e)
          LazyGraph.logger.error(e.backtrace.take_while do |line|
            !line.include?('lazy_graph/node.rb')
          end.join("\n"))

          MissingValue { "#{key} raised exception: #{e.message}" }
        end

        if result.nil? || result.is_a?(MissingValue)
          raise_presence_validation_error!(stack, key, path) if @validate_presence

          @node_context[i] = nil
        else
          @node_context[i] = result
        end
      end

      @node_context[:itself] = input
      @node_context[:stack_ptr] = stack

      conditions_passed = !(@conditions&.any? do |field, allowed_value|
        allowed_value.is_a?(Array) ? !allowed_value.include?(@node_context[field]) : allowed_value != @node_context[field]
      end)

      ex = nil
      result = \
        if conditions_passed
          output = begin
            cast(@fixed_result || @node_context.process!)
          rescue AbortError, ValidationError => e
            raise e
          rescue StandardError => e
            ex = e
            LazyGraph.logger.error(e)
            LazyGraph.logger.error(e.backtrace.take_while do |line|
              !line.include?('lazy_graph/node.rb')
            end.join("\n"))

            if ENV['LAZYGRAPH_OPEN_ON_ERROR'] && !@revealed_src
              require 'shellwords'
              @revealed_src = true
              `sh -c \"$EDITOR '#{Shellwords.escape(e.backtrace.first[/.*:/][...-1])}'\" `
            end

            MissingValue { "#{key} raised exception: #{e.message}" }
          end

          input[key] = output.nil? ? MissingValue { key } : output
        else
          MissingValue { key }
        end

      if conditions_passed
        trace!(stack, exception: ex) do
          {
            output: :"#{stack}.#{key}",
            result: HashUtils.deep_dup(result),
            inputs: @node_context.to_h.except(:itself, :stack_ptr).transform_keys { |k| @input_mapper&.[](k) || k },
            calc: @src,
            **(@conditions ? { conditions: @conditions } : {})
          }
        end
      end

      result
    end

    def trace!(stack, exception: nil)
      return if @debug == 'exceptions' && !exception

      trace_opts = {
        **yield,
        **(exception ? { exception: exception } : {})
      }

      return if @debug.is_a?(Regexp) && !(@debug =~ trace_opts[:output])

      stack.log_debug(**trace_opts)
    end

    def raise_presence_validation_error!(stack, key, path)
      raise ValidationError,
            "Missing required value for #{stack}.#{key} at #{path.to_path_str}"
    end
  end
end
