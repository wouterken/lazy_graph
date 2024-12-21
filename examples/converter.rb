require 'debug'
require 'lazy_graph'

module ConversionAPI
  class Rgb < LazyGraph::Builder
    rules_module :rgb_converter do
      %i[h s l g r b c m y k].each { number _1 }
      string :mode, enum: %i[hsl cmyk rgb]
      one_of [
        { required: %i[r g b], properties: { mode: { const: 'rgb' } } },
        { required: %i[h s l], properties: { mode: { const: 'hsl' } } },
        { required: %i[c m y k], properties: { mode: { const: 'cmyk' } } }
      ]

      object_conditional :color do
        matches :hsl, mode: 'hsl' do
          array :rgb, type: :number, rule: lambda { |h, s, l|
            a = s * [l, 1 - l].min
            f = ->(n, k = (n + h / 30) % 12) { l - a * [[k - 3, 9 - k, 1].min, -1].max }
            [255 * f.call(0), 255 * f.call(8), 255 * f.call(4)]
          }
        end

        matches :cmyk, mode: 'cmyk' do
          array :rgb, type: :number, rule: lambda { |c, m, y, k|
            f = ->(x, k) { 255 * (1 - x) * (1 - k) }
            [f.call(c, k), f.call(m, k), f.call(y, k)]
          }
        end

        matches :rgb, mode: 'rgb' do
          array :rgb, type: :number, rule: :"[${r},${g},${b}]"
        end

        array :rgb, type: :number
      end
    end
  end

  include LazyGraph.bootstrap_app!
end
