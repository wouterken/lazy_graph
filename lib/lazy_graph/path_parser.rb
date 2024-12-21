# frozen_string_literal: true

# LazyGraph supports a bespoke path structure for querying a LazyGraph.
# It has some overlap with
# * JSON path (but supports querying a subset of object properties), and
# * GraphQL (but it supports direct references to deeply nested properties without preserving structure)/
#
# Example query paths and outputs
#
# "employees" => {"employees": [{...whole object...}, {...whole object...}]}
# "employees[id,name]" => {"employees": [{ "id": "3", "name": "John Smith}, { "id": "4", "name": "Jane Smith}]}
# "employees[0..1] => {"employees": [{...whole object...}, {...whole object...}]}"
# "employees[0..1] => {"employees": [{...whole object...}, {...whole object...}]}"
#
module LazyGraph
  module PathParser
    require_relative 'path_parser/path'
    require_relative 'path_parser/path_group'
    require_relative 'path_parser/path_part'
    # This module is responsible for parsing complex path strings into structured components.
    # Public class method to parse the path string
    def self.parse(path, strip_root: false)
      return Path::BLANK if path.nil? || path.empty?

      start = strip_root && path.to_s.start_with?('$.') ? 2 : 0
      parse_recursive(path, start)
    end

    class << self
      # Recursively parses the path starting from index 'start'
      # Returns [Path object, new_index]
      def parse_recursive(path, start)
        parse_structure = {
          parts: [],
          buffer: ''.dup,
          i: start
        }

        parse_main_loop(path, parse_structure)
        parse_finalize(parse_structure)

        Path.new(parts: parse_structure[:parts])
      end

      def parse_main_loop(path, parse_structure)
        while parse_structure[:i] < path.length
          char = path[parse_structure[:i]]
          handle_char(char, path, parse_structure)
        end
      end

      def handle_char(char, path, structure)
        case char
        when '.'
          handle_dot(path, structure)
        when '['
          handle_open_bracket(path, structure)
        when ','
          handle_comma(structure)
        when ']'
          handle_close_bracket(structure)
        else
          structure[:buffer] += char
          structure[:i] += 1
        end
      end

      def handle_dot(path, structure)
        # Check if it's part of a range ('..' or '...')
        if path[structure[:i] + 1] == '.'
          handle_range_dot(path, structure)
        else
          handle_single_dot(structure)
        end
      end

      def handle_range_dot(path, structure)
        if path[structure[:i] + 2] == '.'
          structure[:buffer] += '...'
          structure[:i] += 3
        else
          structure[:buffer] += '..'
          structure[:i] += 2
        end
      end

      def handle_single_dot(structure)
        unless structure[:buffer].strip.empty?
          parsed = parse_buffer(structure[:buffer].strip)
          append_parsed(parsed, structure[:parts])
          structure[:buffer] = ''.dup
        end
        structure[:i] += 1
      end

      def append_parsed(parsed, parts)
        if parsed.is_a?(Array)
          parsed.each { |p| parts << p }
        elsif parsed.is_a?(Range)
          parts << PathGroup.new(options: parsed.map { |p| Path.new(parts: [PathPart.new(part: p.to_sym)]) })
        else
          parts << parsed
        end
      end

      def handle_open_bracket(path, structure)
        unless structure[:buffer].strip.empty?
          paths = structure[:buffer].strip.split('.').map(&:strip)
          paths.each { |p| structure[:parts] << PathPart.new(part: p.to_sym) }
          structure[:buffer] = ''.dup
        end

        closing_bracket = find_matching_bracket(path, structure[:i])
        raise 'Unbalanced brackets in path.' if closing_bracket == -1

        inside = path[(structure[:i] + 1)...closing_bracket]
        elements = split_by_comma(inside)
        parsed_elements = elements.map { |el| parse_recursive(el, 0) }
        path_group = PathGroup.new(options: parsed_elements)
        structure[:parts] << path_group
        structure[:i] = closing_bracket + 1
      end

      def handle_comma(structure)
        unless structure[:buffer].strip.empty?
          parsed = parse_buffer(structure[:buffer].strip)
          append_parsed(parsed, structure[:parts])
          structure[:buffer] = ''.dup
        end
        structure[:i] += 1
      end

      def handle_close_bracket(structure)
        raise 'Unbalanced closing bracket in path.' if structure[:buffer].strip.empty?

        parsed = parse_buffer(structure[:buffer].strip)
        append_parsed(parsed, structure[:parts])
        structure[:buffer] = ''.dup
      end

      def parse_finalize(structure)
        return if structure[:buffer].strip.empty?

        parsed = parse_buffer(structure[:buffer].strip)
        append_parsed(parsed, structure[:parts])
      end

      def find_matching_bracket(path, start)
        depth = 1
        i = start + 1
        while i < path.length
          if path[i] == '['
            depth += 1
          elsif path[i] == ']'
            depth -= 1
            return i if depth.zero?
          end
          i += 1
        end
        -1 # No matching closing bracket found
      end

      def split_by_comma(str)
        elements = []
        buffer = ''.dup
        depth = 0
        str.each_char do |c|
          case c
          when '['
            depth += 1
            buffer << c
          when ']'
            depth -= 1
            buffer << c
          when ','
            if depth.zero?
              elements << buffer.strip
              buffer = ''.dup
            else
              buffer << c
            end
          else
            buffer << c
          end
        end
        elements << buffer.strip unless buffer.strip.empty?
        elements
      end

      def parse_buffer(buffer)
        if buffer.include?('...')
          parse_range(buffer, '...', true)
        elsif buffer.include?('..')
          parse_range(buffer, '..', false)
        elsif buffer.include?('.')
          paths = buffer.split('.').map(&:strip)
          paths.map { |p| PathPart.new(part: p.to_sym) }
        else
          PathPart.new(part: buffer.to_sym)
        end
      end

      def parse_range(buffer, delimiter, exclude_end)
        parts = buffer.split(delimiter)
        return buffer unless parts.size == 2

        Range.new(parts[0].strip, parts[1].strip, exclude_end)
      end
    end
  end
end
