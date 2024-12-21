require 'lazy_graph'

module ShoppingCartTotals
  module API
    class V1 < LazyGraph::Builder
      rules_module :cart do
        array :items do
          string :name
          integer :quantity
          number :price
          number :unit_total, rule: '${quantity} * ${price}'
        end

        object :coupon_codes, invisible: true, rule: :valid_coupons do
          object :".*", pattern_property: true do
            number :discount_abs
            number :discount_percent
            number :min_total
            one_of [
              { required: [:discount_abs] },
              { required: %i[discount_percent min_total] }
            ]
          end
        end

        string :applied_coupon, default: ''
        number :gross, rule: '${items.unit_total}.sum'
        number :discount, rule: 'apply_coupon_code(${coupon_codes[applied_coupon]}, ${gross})'
        number :net, rule: '${gross} - ${discount}'
        number :gst, rule: '(${net} * 0.1).round(2)'
        number :total, rule: '${net} + ${gst}'
      end
    end
  end

  module CouponHelpers
    module_function

    def valid_coupons
      {
        '10OFF' => { discount_abs: 10 },
        '15%OVER100' => { discount_percent: 15, min_total: 100 },
        '20%OVER200' => { discount_percent: 20, min_total: 200 }
      }
    end

    def apply_coupon_code(coupon_code, net)
      return 0 unless coupon_code

      coupon_code[:discount_abs] || net > coupon_code[:min_total] ? net * coupon_code[:discount_percent] / 100.0 : 0
    end
  end

  API::V1.register_helper_modules(CouponHelpers)
  include LazyGraph.bootstrap_app!(reload_paths: [])
end
