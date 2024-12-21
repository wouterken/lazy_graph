module LazyGraph
  class ArrayNode < Node
    # An Array supports the following types of path resolutions.
    # 1. Forward property (assuming child items are objects): arr.property
    # 2. Absolute Index: arr[0], arr[1], arr[2], ...
    # 3. Range: arr[0..2], arr[1...3]
    # 4. All:arr [*]
    # 5. Set of indexes: arr[0, 2, 4]
    #
    # Parts between square brackets are represented as path groups.
    def resolve(
      path,
      stack_memory,
      should_recycle = stack_memory,
      **
    )
      return MissingValue() unless input = stack_memory.frame

      @visited[input.object_id >> 2 ^ path.shifted_id] ||= begin
        path_next = path.next
        if (path_segment = path.segment).is_a?(PathParser::PathGroup)
          unless path_segment.index?
            return input.length.times.map do |index|
              children.fetch_and_resolve(path, input, index, stack_memory)
            end
          end

          return resolve(path_segment.options.first.merge(path_next), stack_memory, nil) if path_segment.options.one?

          return path_segment.options.map { |part| resolve(part.merge(path_next), stack_memory, nil) }
        end

        segment = path_segment&.part
        case segment
        when nil

          unless @children.simple?
            input.length.times do |index|
              @children.fetch_and_resolve(path, input, index, stack_memory)
            end
          end
          input
        when DIGIT_REGEXP
          @children.fetch_and_resolve(path_next, input, segment.to_s.to_i, stack_memory)
        else
          if @child_properties&.key?(segment) || input&.first&.key?(segment)
            input.length.times.map do |index|
              @children.fetch_and_resolve(path, input, index, stack_memory)
            end
          else
            MissingValue()
          end
        end
      end
    ensure
      should_recycle&.recycle!
    end

    def children=(value)
      @children = value
      @child_properties = @children.children[:properties].compare_by_identity if @children.is_object
    end

    def cast(value)
      Array(value)
    end
  end
end
