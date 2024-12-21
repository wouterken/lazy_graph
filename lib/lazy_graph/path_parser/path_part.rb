# frozen_string_literal: true

module LazyGraph
  module PathParser
    INDEX_REGEXP = /\A-?\d+\z/
    # Represents a single part of a path.
    PathPart = Struct.new(:part, keyword_init: true) do
      def index?
        @index ||= part =~ INDEX_REGEXP
      end

      def ==(other)
        return part == other.to_sym if other.is_a?(String)
        return part == other if other.is_a?(Symbol)
        return part == other if other.is_a?(Array)

        super
      end
    end
  end
end
