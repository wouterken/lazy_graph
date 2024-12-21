# frozen_string_literal: true

module LazyGraph
  module PathParser
    # This module is responsible for parsing complex path strings into structured components.

    # Path represents a structured component of a complex path string.
    # It provides methods to navigate and manipulate the path parts.

    Path = Struct.new(:parts, keyword_init: true) do
      def next        = @next ||= parts.length <= 1 ? Path::BLANK : Path.new(parts: parts[1..])
      def empty?      = @empty ||= parts.empty?
      def length      = @length ||= parts.length
      def segment     = @segment ||= parts&.[](0)
      def absolute?   = instance_variable_defined?(:@absolute) ? @absolute : (@absolute = segment&.part.equal?(:'$'))
      def index?      = @index ||= !empty? && segment&.index?
      def identity    = @identity ||= parts&.each_with_index&.reduce(0) { |acc, (p, i)| acc ^ (p.object_id) << (i * 8) }
      def map(&block) = empty? ? self : Path.new(parts: parts.map(&block))
      def shifted_id  = @shifted_id ||= object_id << 28
      def first_path_segment = @first_path_segment ||= absolute? ? self.next.segment : segment

      def merge(other)
        if other.empty?
          self
        else
          empty? ? other : Path.new(parts: parts + other.parts)
        end
      end

      def to_path_str
        @to_path_str ||= create_path_str
      end

      def ==(other)
        return parts == other if other.is_a?(Array)

        super
      end

      private

      def create_path_str
        parts.inject('$') do |path_str, part|
          path_str + \
            if part.is_a?(PathPart)
              ".#{part.part}"
            else
              "[#{part.options.map(&:to_path_str).join(',').delete_prefix('$.')}]"
            end
        end
      end
    end
    Path::BLANK = Path.new(parts: [])
  end
end
