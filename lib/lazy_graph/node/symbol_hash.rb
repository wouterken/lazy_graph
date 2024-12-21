module LazyGraph
  class ObjectNode < Node
    class SymbolHash < ::Hash
      def initialize(input_hash = {})
        super
        merge!(input_hash.transform_keys(&:to_sym))
        compare_by_identity
      end

      def []=(key, value)
        case key
        when Symbol then super(key, value)
        when String then super(key.to_sym, value)
        else super(key.to_s.to_sym, value)
        end
      end

      def [](key)
        case key
        when Symbol then super(key)
        when String then super(key.to_sym)
        else super(key.to_s.to_sym)
        end
      end

      def method_missing(name, *args, &block)
        if key?(name)
          self[name]
        else
          super
        end
      end

      def respond_to_missing?(name, include_private = false)
        key?(name) || super
      end
    end
  end
end
