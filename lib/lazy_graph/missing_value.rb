# frozen_string_literal: true

module LazyGraph
  # Represents a value that is missing or undefined, allowing for graceful handling
  # of method calls and JSON serialization even when the value is not present.
  class MissingValue
    attr_reader :details

    def initialize(details) = @details = details
    def to_s = "MISSING[#{@details}]"
    def inspect = to_s
    def coerce(other) = [self, other]
    def as_json = nil
    def to_h = nil
    def +(other) = other
    def respond_to_missing?(_method_name, _include_private = false) = true
    def to_i = 0
    def to_f = 0.0

    def ==(other)
      return true if other.nil?

      super
    end

    def method_missing(method, *args, &block)
      return super if method == :to_ary
      return self if self == BLANK

      MissingValue.new(:"#{details}##{method}#{args.any? ? :"(#{args.inspect[1...-1]})" : :''}")
    end

    BLANK = new('')
  end
end
