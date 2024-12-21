module LazyGraph
  class ObjectNode < Node
    require_relative 'symbol_hash'

    attr_reader :properties

    # An object supports the following types of path resolutions.
    # 1. Property name: obj.property => value
    # 2. Property name group: obj[property1, property2] =>  { property1: value1, property2: value2 }
    # 3. All [*]
    def resolve(
      path,
      stack_memory,
      should_recycle = stack_memory,
      preserve_keys: false
    )
      input = stack_memory.frame

      @visited[(input.object_id >> 2 ^ path.shifted_id) + preserve_keys.object_id] ||= begin
        return input if input.is_a?(MissingValue)

        path_next = path.next

        if (path_segment = path.segment).is_a?(PathParser::PathGroup)
          return path_segment.options.each_with_object(SymbolHash.new) do |part, object|
            resolve(part.merge(path_next), stack_memory, nil, preserve_keys: object)
          end
        end
        if !segment = path_segment&.part
          @complex_properties_a.each do |key, node|
            node.fetch_and_resolve(path_next, input, key, stack_memory)
          end
          if @complex_pattern_properties_a.any?
            input.keys.each do |key|
              node = !@properties[key] && @complex_pattern_properties_a.find do |(pattern, _value)|
                pattern.match?(key)
              end&.last
              next unless node

              node.fetch_and_resolve(path_next, input, key, stack_memory)
            end
          end
          cast(input)
        elsif (prop = @properties[segment])
          prop.fetch_and_resolve(path_next, input, segment, stack_memory, preserve_keys)
        elsif (_, prop = @pattern_properties.find { |(key, _val)| key.match?(segment) })
          prop.fetch_and_resolve(path_next, input, segment, stack_memory, preserve_keys)
        elsif input&.key?(segment)
          prop = @properties[segment] = lazy_init_node!(input[segment], segment)
          @properties_a = @properties.to_a
          prop.fetch_and_resolve(path_next, input, segment, stack_memory, preserve_keys)
        else
          value = MissingValue()
          preserve_keys ? preserve_keys[segment] = value : value
        end
      end
    ensure
      should_recycle&.recycle!
    end

    def find_resolver_for(segment)
      if segment.equal?(:'$')
        root
      elsif @properties.key?(segment)
        @properties[segment]
      else
        @parent&.find_resolver_for(segment)
      end
    end

    def children=(value)
      @children = value

      @properties = @children.fetch(:properties, {}).compare_by_identity
      @pattern_properties = @children.fetch(:pattern_properties, [])

      @complex_properties_a = @properties.to_a.reject { _2.simple? }
      @complex_pattern_properties_a = @pattern_properties.reject { _2.simple? }

      @has_properties = @properties.any? || @pattern_properties.any?

      return unless @has_properties

      if @pattern_properties.any?
        @property_class = SymbolHash
      else
        invisible = @properties.select { |_k, v| v.invisible }.map(&:first)
        @property_class = LazyGraph.fetch_property_class(
          path,
          { members: @properties.keys + (@debug && !parent ? [:DEBUG] : []),
            invisible: invisible },
          namespace: root.namespace
        )
      end
      define_singleton_method(:cast, lambda { |val|
        if val.is_a?(MissingValue)
          val
        else
          val.is_a?(@property_class) ? val : @property_class.new(val.to_h)
        end
      })
    end
  end
end
