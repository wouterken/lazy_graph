module LazyGraph
  module NodeProperties
    # Builds an Anonymous Struct with the given members
    # Invisible members are ignored when the struct is serialized
    def self.build(members:, invisible:)
      Struct.new(*members, keyword_init: true) do
        define_method(:initialize) do |kws|
          members.each { |k| self[k] = kws[k].then { |v| v.nil? ? MissingValue::BLANK : v } }
        end

        members.each do |m|
          define_method(m) do
            self[m]
          end
        end

        alias_method :original_get, :[]

        define_method(:key?) do |x|
          !original_get(x).equal?(MissingValue::BLANK)
        end

        define_method(:[]=) do |key, val|
          super(key, val)
        end

        define_method(:[]) do |key|
          res = original_get(key)
          res.is_a?(MissingValue) ? nil : res
        end

        define_method(:members) do
          members
        end

        define_method(:invisible) do
          invisible
        end

        def to_hash
          to_h
        end

        def to_h
          HashUtils.strip_missing(self)
        end

        def ==(other)
          return super if other.is_a?(self.class)
          return to_h.eql?(other.to_h.keep_if { |_, v| !v.nil? }) if other.respond_to?(:to_h)

          super
        end

        define_method(:each_key, &members.method(:each))

        def dup
          self.class.new(members.each_with_object({}) { _2[_1] = _2[_1].dup })
        end

        def get_first_of(*props)
          key = props.find do |prop|
            !original_get(prop).is_a?(MissingValue)
          end
          key ? self[key] : MissingValue::BLANK
        end

        def pretty_print(q)
          q.group(1, '<', '>') do
            q.text "#{self.class.name} "
            q.seplist(members.zip(values).reject do |m, v|
              m == :DEBUG || v.nil? || v.is_a?(MissingValue)
            end.to_h) do |k, v|
              q.text "#{k}: "
              q.pp v
            end
          end
        end

        alias_method :keys, :members
      end
    end
  end
end
