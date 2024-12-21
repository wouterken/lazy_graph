# frozen_string_literal: true

module LazyGraph
  module PathParser
    # Represents a group of paths with a list of options, which must all be resolved.
    PathGroup = Struct.new(:options, keyword_init: true) do
      def index?
        @index ||= options.all?(&:index?)
      end

      def ==(other)
        return options == other if other.is_a?(Array)

        super
      end
    end
  end
end
