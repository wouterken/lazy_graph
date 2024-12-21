# frozen_string_literal: true

module LazyGraph
  class Builder
    # This module defines the DSL for building Lazy Graph JSON schemas.
    # Supported helpers
    # * object :name, **opts, &blk
    # * object_conditional :name, **opts, &blk
    #   ⌙ matches &blk
    # * array :name, **opts, &blk
    #   ⌙ items &blk
    # * <primitive> :name, **opts, &blk
    # * date :name, **opts, &blk
    # * decimal :name, **opts, &blk
    # * timestamp :name, **opts, &blk
    # * time :name, **opts, &blk
    #
    module DSL
      def additional_properties(value)
        schema[:additionalProperties] = value
        self
      end

      def required(*keys)
        (schema[:required] ||= []).concat(keys.map(&:to_s)).uniq!
        self
      end

      def default(value)
        schema[:default] = \
          if value.is_a?(Hash)
            HashUtils.deep_merge(schema.fetch(:default, {}), value)
          elsif value.is_a?(Array)
            schema.fetch(:default, []).concat(value).uniq!
          else
            value
          end
        self
      end

      def set_pattern_property(pattern, value)
        raise 'Trying to set a property without a name' unless pattern.is_a?(String) || pattern.is_a?(Symbol)

        pattern = pattern.to_sym
        properties = schema[:patternProperties] ||= {}
        properties[pattern] = \
          if properties.key?(pattern) && %i[object array].include?(properties[pattern][:type])
            HashUtils.deep_merge(properties[pattern], value, key)
          else
            value
          end
        self
      end

      def set_property(key, value)
        raise 'Trying to set a property without a name' unless key.is_a?(String) || key.is_a?(Symbol)

        key = key.to_sym
        properties = schema[:properties] ||= {}
        properties[key] = \
          if properties.key?(key) && %i[object array].include?(properties[key][:type])
            HashUtils.deep_merge(properties[key], value, key)
          else
            value
          end
        self
      end

      def object_conditional(
        name = nil, required: false, pattern_property: false, rule: nil, copy: nil,
        default: nil, description: nil, extend: nil, conditions: nil, **opts, &blk
      )
        new_object = {
          type: :object,
          properties: {},
          additionalProperties: false,
          **(!default.nil? ? { default: default } : {}),
          **(description ? { description: description } : {}),
          validate_presence: required,
          **opts
        }
        @prev_match_cases = @match_cases
        @match_cases = []
        yields(new_object, &lambda {
          blk&.call
          extend&.call
        })

        object_names = @match_cases.map do |match_case|
          rule = rule_from_when(match_case[:when_clause])
          set_property(match_case[:name],
                       { type: :object, rule: rule, rule_location: rule_location, **match_case[:schema] })
          match_case[:name]
        end

        new_object[:rule] = rule_from_first_of(object_names, conditions)
        @match_cases = @prev_match_cases
        required(name) if required && default.nil? && rule.nil?
        pattern_property ? set_pattern_property(name, new_object) : set_property(name, new_object)
      end

      def matches(name, invisible: true, **when_clause, &blk)
        @match_cases << { name: name, when_clause: when_clause, schema: { invisible: invisible } }
        yields(@match_cases.last[:schema], &blk)
      end

      def rule_location
        @dir ||= File.expand_path(File.dirname(__FILE__), '../../../../')
        caller.find { |c| !c.include?(@dir) }.split(':').first(2)
      end

      def object(
        name = nil, required: false, pattern_property: false, rule: nil, copy: nil,
        default: nil, description: nil, extend: nil, **opts, &blk
      )
        rule ||= rule_from_when(opts.delete(:when)) if opts[:when]
        rule ||= rule_from_first_of(opts.delete(:first_of)) if opts[:first_of]
        rule ||= rule_from_copy(copy)
        new_object = {
          type: :object,
          properties: {},
          additionalProperties: false,
          **(!default.nil? ? { default: default } : {}),
          **(description ? { description: description } : {}),
          **(rule ? { rule: rule, rule_location: rule_location } : {}),
          validate_presence: required,
          **opts
        }
        yields(new_object, &lambda {
          blk&.call
          extend&.call
        })
        required(name) if required && default.nil? && rule.nil?
        pattern_property ? set_pattern_property(name, new_object) : set_property(name, new_object)
      end

      def primitive(
        name = nil, type, required: false, pattern_property: false,
        default: nil, description: nil, enum: nil,
        rule: nil, copy: nil, **additional_options, &blk
      )
        rule ||= rule_from_copy(copy)
        new_primitive = {
          type: type,
          **(enum ? { enum: enum } : {}),
          **(!default.nil? ? { default: default } : {}),
          **(description ? { description: description } : {}),
          **(rule ? { rule: rule, rule_location: rule_location } : {}),
          **additional_options
        }
        yields(new_primitive, &blk)
        required(name) if required && default.nil? && rule.nil?
        pattern_property ? set_pattern_property(name, new_primitive) : set_property(name, new_primitive)
      end

      def decimal(name = nil, required: false, pattern_property: false, default: nil, description: nil, rule: nil, copy: nil,
                  **opts, &blk)
        rule ||= rule_from_copy(copy)
        # Define the decimal schema supporting multiple formats
        new_decimal = {
          anyOf: [
            {
              type: :string,
              # Matches valid decimals with optional exponentials
              pattern: '^-?(\\d+\\.\\d+|\\d+|\\d+e[+-]?\\d+|\\d+\\.\\d+e[+-]?\\d+)$'

            },
            # Allows both float and int
            {
              type: :number #
            },
            {
              type: :integer
            }
          ],
          type: :decimal,
          **(!default.nil? ? { default: default } : {}),
          **(description ? { description: description } : {}),
          **(rule ? { rule: rule, rule_location: rule_location } : {}),
          validate_presence: required,
          **opts
        }
        yields(new_decimal, &blk)
        required(name) if required && default.nil? && rule.nil?
        pattern_property ? set_pattern_property(name, new_decimal) : set_property(name, new_decimal)
      end

      def timestamp(name = nil, required: false, pattern_property: false, default: nil, description: nil, rule: nil, copy: nil,
                    **opts, &blk)
        rule ||= rule_from_copy(copy)
        new_timestamp = {
          anyOf: [
            {
              type: :string,
              # Matches ISO 8601 timestamp without timezone
              pattern: '^\d{4}-\d{2}-\d{2}(T\d{2}(:\d{2}(:\d{2}(\.\d{1,3})?)?)?(Z|[+-]\d{2}(:\d{2})?)?)?$'
            },
            {
              type: :number # Allows numeric epoch timestamps
            },
            {
              type: :integer # Allows both float and int
            }
          ],
          type: :timestamp, # Custom extended type
          **(!default.nil? ? { default: default } : {}),
          **(description ? { description: description } : {}),
          **(rule ? { rule: rule, rule_location: rule_location } : {}),
          validate_presence: required,
          **opts
        }
        yields(new_timestamp, &blk)
        required(name) if required && default.nil? && rule.nil?
        pattern_property ? set_pattern_property(name, new_timestamp) : set_property(name, new_timestamp)
      end

      def time(name = nil, required: false, pattern_property: false, default: nil, description: nil, rule: nil, copy: nil,
               **opts, &blk)
        rule ||= rule_from_copy(copy)
        new_time = {
          type: :time, # Custom extended type
          # Matches HH:mm[:ss[.SSS]]
          pattern: '^\\d{2}:\\d{2}(:\\d{2}(\\.\\d{1,3})?)?$',
          **(!default.nil? ? { default: default } : {}),
          **(description ? { description: description } : {}),
          **(rule ? { rule: rule, rule_location: rule_location } : {}),
          validate_presence: required,
          **opts
        }
        yields(new_time, &blk)
        required(name) if required && default.nil? && rule.nil?
        pattern_property ? set_pattern_property(name, new_time) : set_property(name, new_time)
      end

      def date(name = nil, required: false, pattern_property: false, default: nil, description: nil, rule: nil, copy: nil,
               **opts, &blk)
        rule ||= rule_from_copy(copy)
        new_date = {
          anyOf: [
            {
              type: :string,
              # Matches ISO 8601 date format
              pattern: '^\\d{4}-\\d{2}-\\d{2}$'
            }
          ],
          type: :date, # Custom extended type
          **(!default.nil? ? { default: default } : {}),
          **(description ? { description: description } : {}),
          **(rule ? { rule: rule, rule_location: rule_location } : {}),
          validate_presence: required,
          **opts
        }
        yields(new_date, &blk)
        required(name) if required && default.nil? && rule.nil?
        pattern_property ? set_pattern_property(name, new_date) : set_property(name, new_date)
      end

      %i[boolean string const integer number null].each do |type|
        define_method(type) do |
          name = nil, required: false, pattern_property: false,
          default: nil, description: nil, enum: nil, rule: nil, copy: nil,
          **additional_options, &blk|
          primitive(
            name, type, required: required, pattern_property: pattern_property, enum: enum,
                        default: default, rule: rule, rule_location: rule_location, description: description,
                        **additional_options, &blk
          )
        end
      end

      def dependencies(dependencies)
        schema[:dependencies] = HashUtils.deep_merge(schema[:dependencies] || {}, dependencies)
      end

      def one_of(one_of)
        schema[:oneOf] = (schema[:one_of] || []).concat(one_of).uniq
      end

      def any_of(any_of)
        schema[:anyOf] = (schema[:any_of] || []).concat(any_of).uniq
      end

      def array(name = nil, required: false, pattern_property: false, default: nil, description: nil, rule: nil, copy: nil,
                type: :object, extend: nil, **opts, &block)
        rule ||= rule_from_copy(copy)
        new_array = {
          type: :array,
          **(!default.nil? ? { default: default } : {}),
          **(description ? { description: description } : {}),
          **(rule ? { rule: rule, rule_location: rule_location } : {}),
          **opts,
          items: { properties: {} }.tap do |items|
            yields(items) do
              send(type, :items, extend: extend, &block)
            end
          end[:properties][:items]
        }
        required(name) if required && default.nil? && rule.nil?
        pattern_property ? set_pattern_property(name, new_array) : set_property(name, new_array)
      end

      def items(&blk)
        yields(schema[:items], &blk)
      end

      def yields(other)
        raise ArgumentError, 'Builder DSL used outside of rules module' unless schema
        return unless block_given?

        prev_schema = schema
        self.schema = other
        yield
        self.schema = prev_schema
      end

      def rule_from_copy(copy)
        return unless copy

        "${#{copy}}"
      end

      def rule_from_when(when_clause)
        inputs = when_clause.keys
        conditions = when_clause
        calc = "{#{when_clause.keys.map { |k| "#{k}: #{k}}" }.join(', ')}"
        {
          inputs: inputs,
          conditions: conditions,
          fixed_result: when_clause,
          calc: calc
        }
      end

      def rule_from_first_of(prop_list, conditions = nil)
        prop_list += conditions.keys if conditions
        {
          inputs: prop_list,
          calc: "itself.get_first_of(:#{prop_list.join(', :')})",
          **(conditions ? { conditions: conditions } : {})
        }
      end

      def depends_on(*dependencies)
        @resolved_dependencies ||= Hash.new do |h, k|
          h[k] = true
          send(k) # Load dependency once
        end
        dependencies.each(&@resolved_dependencies.method(:[]))
      end
    end
  end
end
