# frozen_string_literal: true

module LazyGraph
  module HashUtils
    module_function

    # Deeply duplicates a nested hash or array, preserving object identity.
    # Optionally symbolizes keys on the way, and/or generates a signature.
    def deep_dup(obj, symbolize: false, signature: nil)
      case obj
      when Hash
        obj.each_with_object(symbolize ? {}.compare_by_identity : {}) do |(key, value), result|
          key = \
            if !symbolize || key.is_a?(Symbol)
              key
            else
              key.is_a?(String) ? key.to_sym : key.to_s.to_sym
            end

          signature[0] ^= key.object_id if signature
          result[key] = deep_dup(value, symbolize: symbolize, signature: signature)
        end
      when Struct
        deep_dup(obj.to_h, symbolize: symbolize, signature: signature)
      when Array
        obj.map { |value| deep_dup(value, symbolize: symbolize, signature: signature) }
      when String, Numeric, TrueClass, FalseClass, NilClass
        signature[0] ^= obj.hash if signature
        obj
      else
        obj
      end
    end

    def deep_merge(hash, other_hash, path = '')
      hash.merge(other_hash.transform_keys(&:to_sym)) do |key, this_val, other_val|
        current_path = path.empty? ? key.to_s : "#{path}.#{key}"

        if this_val.is_a?(Hash) && other_val.is_a?(Hash) && other_val != this_val
          deep_merge(this_val, other_val, current_path)
        elsif this_val.is_a?(Array) && other_val.is_a?(Array) && other_val != this_val
          (this_val | other_val)
        else
          if this_val != other_val && !(this_val.is_a?(Proc) && other_val.is_a?(Proc))
            LazyGraph.logger.warn("Conflicting values at #{current_path}: #{this_val.inspect} != #{other_val.inspect}")
          end
          other_val
        end
      end
    end

    def strip_missing(obj, parent_list = {}.compare_by_identity)
      return { '^ref': :circular } if (circular_dependency = parent_list[obj])

      parent_list[obj] = true
      case obj
      when Hash
        obj.each_with_object({}) do |(key, value), obj|
          next if value.is_a?(MissingValue)
          next if value.nil?

          obj[key] = strip_missing(value, parent_list)
        end
      when Struct
        obj.members.each_with_object({}) do |key, res|
          value = obj.original_get(key)
          next if value.is_a?(MissingValue)
          next if value.nil?
          next if obj.invisible.include?(key)

          res[key] = strip_missing(obj[key], parent_list)
        end
      when Array
        obj.map { |value| strip_missing(value, parent_list) }
      when MissingValue
        nil
      else
        obj
      end
    ensure
      parent_list.delete(obj) unless circular_dependency
    end
  end
end
