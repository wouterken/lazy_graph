# frozen_string_literal: true

module LazyGraph
  # Module to provide lazy graph functionalities using stack pointers.
  POINTER_POOL = []

  StackPointer = Struct.new(:parent, :frame, :depth, :recursion_depth, :key, :root) do
    attr_accessor :pointer_cache

    # Pushes a new frame onto the stack, creating or reusing a StackPointer.
    # Frames represent activation contexts; keys are identifiers within those frames.
    def push(frame, key)
      ptr = POINTER_POOL.pop || StackPointer.new
      ptr.parent = self
      ptr.root = root || self
      ptr.frame = frame
      ptr.key = key
      ptr.depth = depth + 1
      ptr.recursion_depth = recursion_depth
      ptr.pointer_cache&.clear
      ptr
    end

    # Recycles the current StackPointer by adding it back to the pointer pool.
    # Once recycled, this instance should no longer be used unless reassigned by push.
    def recycle!
      POINTER_POOL.push(self)
      nil
    end

    # Retrieves the StackPointer at a specific index in the upward chain of parents.
    def ptr_at(index)
      @pointer_cache ||= {}.compare_by_identity
      @pointer_cache[index] ||= depth == index ? self : parent&.ptr_at(index)
    end

    # Handles method calls not explicitly defined in this class by delegating them
    # first to the frame, then to the parent, recursively up the stack.
    def method_missing(name, *args, &block)
      if frame.respond_to?(name)
        frame.send(name, *args, &block)
      elsif parent
        parent.send(name, *args, &block)
      else
        super
      end
    end

    # Returns the key associated with this stack pointer's frame.
    def index
      key
    end

    # Logs debugging information related to this stack pointer in the root frame's DEBUG section.
    def log_debug(**log_item)
      root.frame[:DEBUG] = [] if !root.frame[:DEBUG] || root.frame[:DEBUG].is_a?(MissingValue)
      root.frame[:DEBUG] << { **log_item, location: to_s }
      nil
    end

    # Determines if the stack pointer can respond to a missing method by mimicking the behavior
    # of the frame or any parent stack pointers recursively.
    def respond_to_missing?(name, include_private = false)
      frame.respond_to?(name, include_private) || parent.respond_to?(name, include_private)
    end

    # Returns a string representation of the stacking path of keys up to this pointer.
    def to_s
      if parent
        "#{parent}#{key.to_s =~ /\d+/ ? "[#{key}]" : ".#{key}"}"
      else
        key.to_s
      end
    end
  end
end
