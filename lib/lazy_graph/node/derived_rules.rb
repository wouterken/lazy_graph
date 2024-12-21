# frozen_string_literal: true

require 'prism'
require 'securerandom'

module LazyGraph
  class Node
    module DerivedRules
      PLACEHOLDER_VAR_REGEX = /\$\{[^}]+\}/
      # Derived input rules can be provided in a wide variety of formats,
      # this function handles them all.
      #
      # 1. A simple string or symbol: 'a.b.c'. The value at the nodes is simply set to the resolved value
      #
      # 2. Alternatively, you must split the inputs and the rule.
      #  derived[:inputs]
      #  a. Inputs as strings or symbols, e.g. inputs: ['position', 'velocity'].
      #   These paths are resolved and made available within the rule by the same name
      #  b. Inputs as a map of key-value pairs, e.g. inputs: { position: 'a.b.c', velocity: 'd.e.f' },
      #   These are resolved and made available within the rule by the mapped name
      #
      # 3. derived[:calc]
      #  The rule can be a simple string of Ruby code OR (this way we can encode entire lazy graphs as pure JSON)
      #  A ruby block.
      def build_derived_inputs(derived, helpers)
        @resolvers = {}.compare_by_identity
        @path_cache = {}.compare_by_identity
        @resolution_stack = {}.compare_by_identity

        derived = interpret_derived_proc(derived) if derived.is_a?(Proc)
        derived = { inputs: derived.to_s } if derived.is_a?(String) || derived.is_a?(Symbol)
        derived[:inputs] = parse_derived_inputs(derived)
        @fixed_result = derived[:fixed_result]
        @copy_input = true if !derived[:calc] && derived[:inputs].size == 1
        extract_derived_src(derived) if @debug

        @inputs_optional = derived[:calc].is_a?(Proc)
        derived[:calc] = parse_rule_string(derived) if derived[:calc].is_a?(String) || derived[:calc].is_a?(Symbol)

        @node_context = create_derived_input_context(derived, helpers)
        @inputs = map_derived_inputs_to_paths(derived[:inputs])
        @conditions = derived[:conditions]
        @derived = true
      end

      def interpret_derived_proc(derived)
        src, requireds, optionals, keywords, loc = DerivedRules.extract_expr_from_source_location(derived.source_location)
        body = src.body&.slice || ''
        @src = body.lines.map(&:strip)
        offset = src.slice.lines.length - body.lines.length
        inputs, conditions = parse_args_with_conditions(requireds, optionals, keywords)

        {
          inputs: inputs,
          mtime: File.mtime(derived.source_location.first),
          conditions: conditions,
          calc: instance_eval(
            "->(#{inputs.keys.map { |k| "#{k}=self.#{k}" }.join(', ')}){ #{body}}",
            # rubocop:disable:next-line
            derived.source_location.first,
            # rubocop:enable
            derived.source_location.last + offset
          )
        }
      end

      def parse_args_with_conditions(requireds, optionals_with_conditions, keywords_with_conditions)
        keywords = requireds.map { |r| [r, r] }.to_h
        conditions = {}
        keywords_with_conditions.map do |k, v|
          path, condition = v.split('=')
          keywords[k] = path
          conditions[k] = eval(condition) if condition
        end
        optionals_with_conditions.each do |optional_with_conditions|
          keywords[optional_with_conditions.name] = optional_with_conditions.name
          conditions[optional_with_conditions.name] = eval(optional_with_conditions.value.slice)
        end
        [keywords, conditions.any? ? conditions : nil]
      end

      def self.get_file_body(file_path)
        @file_body_cache ||= {}
        if @file_body_cache[file_path]&.last.to_i < File.mtime(file_path).to_i
          @file_body_cache[file_path] = [IO.readlines(file_path), File.mtime(file_path).to_i]
        end
        @file_body_cache[file_path]&.first
      end

      def self.extract_expr_from_source_location(source_location)
        @derived_proc_cache ||= {}
        mtime = File.mtime(source_location.first).to_i
        if @derived_proc_cache[source_location]&.last.to_i.< mtime
          @derived_proc_cache[source_location] = begin
            source_lines = get_file_body(source_location.first)

            proc_line = source_location.last - 1
            first_line = source_lines[proc_line]
            until first_line =~ /(?:lambda|proc|->)/ || proc_line.zero?
              proc_line -= 1
              first_line = source_lines[proc_line]
            end
            lines = source_lines[proc_line..]
            lines[0] = lines[0][/(?:lambda|proc|->).*/]
            src_str = ''.dup
            intermediate = nil
            lines.each do |line|
              token_count = 0
              line.split(/(?=\s|;|\)|\})/).each do |token|
                src_str << token
                token_count += 1
                intermediate = Prism.parse(src_str)
                next unless intermediate.success? && token_count > 1

                break
              end
              break if intermediate.success?
            end

            raise 'Source Extraction Failed' unless intermediate.success?

            src = intermediate.value.statements.body.first.yield_self do |s|
              s.type == :call_node ? s.block : s
            end
            requireds = (src.parameters&.parameters&.requireds || []).map(&:name)
            optionals = src.parameters&.parameters&.optionals || []
            keywords =  (src.parameters&.parameters&.keywords || []).map do |kw|
              [kw.name, kw.value.slice.gsub(/^_\./, '$.')]
            end.to_h
            [src, requireds, optionals, keywords, proc_line, mtime]
          end
        end

        @derived_proc_cache[source_location]
      rescue StandardError => e
        LazyGraph.logger.error(e.message)
        LazyGraph.logger.error(e.backtrace.join("\n"))
        raise "Failed to extract expression from source location: #{source_location}. Ensure the file exists and the line number is correct. Extraction from a REPL is not supported"
      end

      def parse_derived_inputs(derived)
        inputs = derived[:inputs]
        case inputs
        when Symbol, String
          if !derived[:calc]
            @src ||= inputs
            input_hash = {}
            @input_mapper = {}
            calc = inputs.gsub(PLACEHOLDER_VAR_REGEX) do |match|
              sub = input_hash[match[2...-1]] ||= "a#{::SecureRandom.hex(8)}"
              @input_mapper[sub.to_sym] = match[2...-1].to_sym
              sub
            end
            derived[:calc] = calc unless calc == input_hash.values.first
            input_hash.invert
          else
            { inputs.to_s.gsub(/[^(?:[A-Za-z][A-Za-z0-9_])]/, '__') => inputs.to_s.freeze }
          end
        when Array
          pairs = inputs.last.is_a?(Hash) ? inputs.pop : {}
          inputs.map { |v| { v.to_s.gsub(/[^(?:[A-Za-z][A-Za-z0-9_])]/, '__') => v } }.reduce(pairs, :merge)
        when Hash
          inputs
        else
          {}
        end.transform_values { |v| PathParser.parse(v) }
      end

      def extract_derived_src(derived)
        return @src ||= derived[:calc].to_s.lines unless derived[:calc].is_a?(Proc)

        @src ||= begin
          extract_expr_from_source_location(derived[:calc].source_location).body.slice.lines.map(&:strip)
        rescue StandardError
          ["Failed to extract source from proc #{derived}"]
        end
      end

      def parse_rule_string(derived)
        calc_str = derived[:calc]
        node_path = path

        src = <<~RUBY, @rule_location&.first, @rule_location&.last.to_i - 2
          ->{
            begin
              #{calc_str}
            rescue StandardError => e;
              LazyGraph.logger.error("Exception in \#{calc_str} => \#{node_path}. \#{e.message}")
              raise e
            end
            }
        RUBY

        instance_eval(*src)
      rescue SyntaxError
        missing_value = MissingValue { "Syntax error in #{derived[:src]}" }
        -> { missing_value }
      end

      def create_derived_input_context(derived, helpers)
        return if @copy_input

        Struct.new(*(derived[:inputs].keys.map(&:to_sym) + %i[itself stack_ptr])) do
          def missing?(value) = value.is_a?(LazyGraph::MissingValue) || value.nil?
          helpers&.each { |h| include h }

          define_method(:process!, &derived[:calc]) if derived[:calc].is_a?(Proc)
          def method_missing(name, *args, &block)
            stack_ptr.send(name, *args, &block)
          end

          def respond_to_missing?(name, include_private = false)
            stack_ptr.respond_to?(name, include_private)
          end
        end.new
      end

      def resolver_for(path)
        segment = path.segment.part
        return root.properties[path.next.segment.part] if segment == :'$'

        (segment == name ? parent.parent : @parent).find_resolver_for(segment)
      end

      def rule_definition_backtrace
        if @rule_location && @rule_location.size >= 2
          rule_file, rule_line = @rule_location
          rule_entry = "#{rule_file}:#{rule_line}:in `rule`"
        else
          rule_entry = 'unknown_rule_location'
        end

        current_backtrace = caller.reverse.take_while { |line| !line.include?('/lib/lazy_graph/') }.reverse
        [rule_entry] + current_backtrace
      end

      def map_derived_inputs_to_paths(inputs)
        inputs.values.map.with_index do |path, idx|
          segments = path.parts.map.with_index do |segment, i|
            if segment.is_a?(PathParser::PathGroup) &&
               segment.options.length == 1 && !((resolver = resolver_for(segment.options.first)) || segment.options.first.segment.part.to_s =~ /\d+/)
              raise(ValidationError.new(
                "Invalid dependency in #{@path}: #{segment.options.first.to_path_str}  cannot be resolved."
              ).tap { |e| e.set_backtrace(rule_definition_backtrace) })
            end

            resolver ? [i, resolver] : nil
          end.compact
          resolver = resolver_for(path)

          unless resolver
            raise(ValidationError.new(
              "Invalid dependency in #{@path}: #{path.to_path_str}  cannot be resolved."
            ).tap { |e| e.set_backtrace(rule_definition_backtrace) })
          end

          [path, resolver, idx, segments.any? ? segments : nil]
        end
      end
    end
  end
end
