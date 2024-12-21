require 'minitest/autorun'
require 'lazy_graph'
require 'debug'

class LazyGraphCoreTest < Minitest::Test
  LazyGraph.logger = Logger.new(nil)

  CartBase = Class.new(LazyGraph::Builder) do
    rules_module :cart_base do
      object :cart do
        array :items, required: true do
          string :name, required: true
          number :price, default: 1.0
          number :quantity, default: 1
          number :total, rule: '${price} * ${quantity}'
        end

        number :cart_total, rule: '${items.total}.sum'
      end
    end
  end

  SpaceshipBase = Class.new(LazyGraph::Builder) do
    rules_module :spaceship do
      object :spaceship do
        array :components do
          number :power
          string :type
          object :attributes do
            number :weight
            number :height
            number :depth
            number :volume, rule: '${weight} * ${height} * ${depth}'
          end
        end
        number :total_power, rule: '${components.power}.sum'
        number :volume, rule: lambda { |attributes: components.attributes|
          attributes.map(&:volume).sum
        }
        array :crew do
          string :name
          number :age
          number :position_id, required: true
          object :position, rule: '${positions[position_id]}' do
            string :name
            number :salary
          end
          object :no_explicit_props, rule: '{hello: 1, world: 2, name: ${name}}'
        end
        number :average_age, rule: '${crew.age}.sum / ${crew}.size'
        number :average_salary, rule: '${crew.position.salary}.sum / ${crew}.size'
      end

      object :positions do
        object :'.*', pattern_property: true do
          string :name, required: true
          number :salary, required: true
        end
      end
    end
  end

  def setup
    @graph_class = CartBase
    @graph = @graph_class.cart_base.build!
    @context = SpaceshipBase.spaceship.build!(debug: true, validate: true).context(
      spaceship: {
        components: [
          { power: 100, type: 'engine', attributes: { weight: 1000, height: 100, depth: 105 } },
          { power: 200, type: 'shield', attributes: { weight: 2000, height: 200, depth: 105 } }
        ],
        crew: [
          { name: 'Alice', age: 30, position_id: 1 },
          { name: 'Bob', age: 40, position_id: 2 },
          { name: 'Steven', age: 50, position_id: 3 }
        ]
      },
      positions: {
        1 => { name: 'Captain', salary: 100_000 },
        2 => { name: 'Engineer', salary: 50_000 },
        3 => { name: 'Janitor', salary: 20_000 }
      }
    )
  end

  def test_it_can_build_a_graph
    assert @graph
  end

  def test_it_can_build_an_empty_context
    assert @graph.context({})
  end

  def test_it_can_be_queried
    assert_nil @graph.context({})['cart'].to_h
  end

  def test_it_can_use_non_empty_context
    assert_equal @graph.context(
      {
        cart: {
          items: [
            { name: 'item1', price: 1.0, quantity: 1 }
          ]
        }
      }
    ).cart.items, [
      CartBase::CartItems.new({ name: 'item1', price: 1.0, quantity: 1, total: 1.0 })
    ]
  end

  def test_it_can_generate_debug_output
    assert_equal @graph_class.cart_base.build!(debug: true).context(
      {
        cart: {
          items: [
            {
              name: 'item1',
              price: 1.0,
              quantity: 1
            }
          ]
        }
      }
    ).resolve('cart.items')[:debug_trace], [
      {
        output: :"$.cart.items[0].total",
        result: 1.0,
        inputs: { price: 1.0, quantity: 1 },
        calc: '${price} * ${quantity}',
        location: '$.cart.items[0]'
      }
    ]
  end

  def test_it_can_use_default_values
    assert_equal @graph.context(
      {
        cart: {
          items: [
            { name: 'item1' }
          ]
        }
      }
    ).get_json('cart.items'), [{ name: 'item1', price: 1.0, quantity: 1, total: 1.0 }]
  end

  def test_it_can_use_default_values_with_debug
    assert_equal @graph_class.cart_base.build!(debug: true).context(
      {
        cart: {
          items: [
            { name: 'item1' }
          ]
        }
      }
    ).resolve('cart.items')[:debug_trace], [
      {
        output: :"$.cart.items[0].total",
        result: 1.0,
        inputs: { price: 1.0, quantity: 1 },
        calc: '${price} * ${quantity}',
        location: '$.cart.items[0]'
      }
    ]
  end

  def test_it_raises_on_invalid_inputs
    assert_raises(LazyGraph::ValidationError) do
      @graph_class.cart_base.build!(validate: true).context(
        {
          cart: {
            items: [
              { name: 'item1', price: 'invalid' }
            ]
          }
        }
      ).cart
    end
  end

  def test_it_doesnt_freeze_on_circular_references
    graph = Class.new(LazyGraph::Builder) do
      rules_module :circular do
        object :circular do
          object :child_a, rule: :'${child_b}'
          object :child_b, rule: :'${child_c}'
          object :child_c, rule: :'${child_a}'
        end
      end
    end
    # Dependencies that failed resolution due to circular dependencies are not included in the context
    assert_equal graph.circular.build!.context({ circular: {} }).circular.to_h, {}

    # Circular dependencies are detected and an error will be present in the debug log.
    assert graph.circular.build!(debug: true).context({ circular: {} }).debug(:circular)[0][:exception] =~ /Infinite Recursion/
  end

  def test_dsl_dependencies_one_of
    graph = Class.new(LazyGraph::Builder) do
      rules_module :temperature do
        number :celsius, rule: '(${fahrenheit} - 32) * (5 / 9.0)'
        number :fahrenheit, rule: '(${celsius} * (9 / 5.0)) + 32'
        one_of [
          { required: [:celsius] },
          { required: [:fahrenheit] }
        ]
      end
    end
    assert_equal graph.temperature.build!(validate: true).context({ celsius: 30 }).fahrenheit, 86
    assert_equal graph.temperature.build!(validate: true).context({ fahrenheit: 86 }).celsius, 30

    # Missing one-of dependency
    assert_raises(LazyGraph::ValidationError) { graph.temperature.build!(validate: true).context({}).celsius }

    # Fulfilling both dependencies
    assert_raises(LazyGraph::ValidationError) do
      graph.temperature.build!(validate: true).context({ celsius: 15, fahrenheit: 19_293 }).celsius
    end
  end

  def test_dsl_dependencies_any_of
    any_of_graph = Class.new(LazyGraph::Builder) do
      rules_module :ice_cream do
        string :scoop_flavor
        string :cone_flavor
        string :topping
        any_of [
          { required: [:scoop_flavor] },
          { required: [:cone_flavor] },
          { required: [:topping] }
        ]
      end
    end

    assert_equal any_of_graph.ice_cream.build!(validate: true).context({ scoop_flavor: 'vanilla' }).scoop_flavor,
                 'vanilla'

    # Can match more than one for an any_of
    assert_equal any_of_graph.ice_cream.build!(validate: true).context({ scoop_flavor: 'vanilla', cone_flavor: 'hokey-pokey' }).scoop_flavor,
                 'vanilla'

    # Missing all dependencies
    assert_raises(LazyGraph::ValidationError) { any_of_graph.ice_cream.build!(validate: true).context({}).scoop_flavor }
  end

  def test_dsl_dependencies_complex
    complex_graph = Class.new(LazyGraph::Builder) do
      rules_module :complex do
        boolean :should_have_a
        boolean :should_have_b
        string :a
        number :b

        dependencies(
          should_have_a: { required: [:a] },
          should_have_b: { required: [:b] }
        )
      end
    end

    assert_equal complex_graph.complex.build!(validate: true).context({ a: 'hello', should_have_a: true }).a, 'hello'
    assert_equal complex_graph.complex.build!(validate: true).context({ b: 123, should_have_b: true }).b, 123
    assert_raises(LazyGraph::ValidationError) do
      complex_graph.complex.build!(validate: true).context({ should_have_a: true }).a
    end
  end

  def test_dsl_requires
    simple_requires_graph = Class.new(LazyGraph::Builder) do
      rules_module :adder do
        number :a, required: true
        number :b, required: true
        number :sum, rule: '${a} + ${b}'
      end
    end

    assert_equal simple_requires_graph.adder.build!(validate: true).context({ a: 1, b: 2 }).sum, 3
    assert_raises(LazyGraph::ValidationError) do
      simple_requires_graph.adder.build!(validate: true).context({ a: 1 }).sum
    end
  end

  def test_dsl_match_clause
    match_clause_graph = Class.new(LazyGraph::Builder) do
      rules_module :i18n do
        string :locale, enum: %w[en es fr], required: true
        object_conditional :i18n do
          matches :en, locale: 'en' do
            string :greeting, default: 'Hello'
            string :farewell, default: 'Goodbye'
          end

          matches :es, locale: 'es' do
            string :greeting, default: 'Hola'
            string :farewell, default: 'Adios'
          end

          matches :fr, locale: 'fr' do
            string :greeting, default: 'Bonjour'
            string :farewell, default: 'Au revoir'
          end
        end
      end
    end

    # assert_equal match_clause_graph.i18n.build!(validate: true).context({ locale: 'en' }).i18n.greeting, 'Hello'
    assert_equal match_clause_graph.i18n.build!(validate: true).context({ locale: 'es' }).i18n.farewell, 'Adios'

    assert_raises(LazyGraph::ValidationError) do
      match_clause_graph.i18n.build!(validate: true).context({}).i18n.greeting
    end
  end

  def test_rule_as_simple_string
    # Simple strings as rules are treated as references
    simple_string_graph = Class.new(LazyGraph::Builder) do
      rules_module :simple_reference do
        string :hello, default: 'world'
        string :a, rule: '${hello}'
        string :b, rule: '${hello}'
      end
    end

    assert_equal simple_string_graph.simple_reference.build!.context({}).a, 'world'
    assert_equal simple_string_graph.simple_reference.build!.context({}).b, 'world'
  end

  def test_simple_string_with_placeholders
    # Strings with placeholders are evaluated as expressions with dependencies
    simple_string_graph = Class.new(LazyGraph::Builder) do
      rules_module :string_with_placeholders do
        number :num, default: 10
        number :a, rule: '${num} + ${num}'
        number :b, rule: :'${num} * ${num}'
        string :c, rule: '${num} + ${num}'
      end
    end

    assert_equal simple_string_graph.string_with_placeholders.build!.context({}).a, 20
    assert_equal simple_string_graph.string_with_placeholders.build!.context({}).b, 100
    assert_equal simple_string_graph.string_with_placeholders.build!.context({}).c, '20'
  end

  def test_explicit_dependencies_array
    # Strings with placeholders are evaluated as expressions with dependencies
    simple_string_graph = Class.new(LazyGraph::Builder) do
      rules_module :string_with_placeholders do
        array :numbers, type: :number, default: [1, 2, 3, 4, 5]
        boolean :get_first, default: true
        number :first_or_last, rule: { inputs: %i[numbers get_first], calc: 'get_first ? numbers[0] : numbers[-1]' }
      end
    end

    assert_equal simple_string_graph.string_with_placeholders.build!.context({ get_first: true }).first_or_last, 1
    assert_equal simple_string_graph.string_with_placeholders.build!.context({ get_first: false }).first_or_last, 5
  end

  def test_explicit_dependencies_map
    simple_string_graph = Class.new(LazyGraph::Builder) do
      rules_module :string_with_placeholders do
        array :numbers, type: :number, default: [1, 2, 3, 4, 5]
        boolean :get_first, default: true

        number :first_or_last,
               rule: {
                 inputs: [:get_first, { first: 'numbers[0]', last: 'numbers[4]' }],
                 calc: 'get_first ? first : last'
               }
      end
    end

    assert_equal simple_string_graph.string_with_placeholders.build!.context({ get_first: true }).first_or_last, 1
    assert_equal simple_string_graph.string_with_placeholders.build!.context({ get_first: false }).first_or_last, 5
  end

  def test_with_proc_input
    simple_string_graph = Class.new(LazyGraph::Builder) do
      rules_module :string_with_placeholders do
        array :numbers, type: :number, default: [1, 2, 3, 4, 5]
        boolean :get_first, default: true
        number :first_or_last, rule: lambda { |get_first, first: numbers[0], last: numbers[4]|
          get_first ? first : last
        }
      end
    end

    assert_equal simple_string_graph.string_with_placeholders.build!.context({ get_first: true }).first_or_last, 1
    assert_equal simple_string_graph.string_with_placeholders.build!.context({ get_first: false }).first_or_last, 5
  end

  def test_query_array_syntax
    has_list_class = Class.new(LazyGraph::Builder) do
      rules_module :books do
        array :books do
          string :name
          number :pages
          boolean :is_long, rule: '${pages} > 200'
        end
      end
    end

    assert_equal \
      has_list_class.books.build!.context(
        { books: [
          { name: 'book1', pages: 100 },
          { name: 'book2', pages: 200 },
          { name: 'book3', pages: 300 }
        ] }
      ).get('books'), \
      [
        { name: 'book1', pages: 100, is_long: false },
        { name: 'book2', pages: 200, is_long: false },
        { name: 'book3', pages: 300, is_long: true }
      ]

    assert_equal \
      has_list_class.books.build!.context(
        { books: [
          { name: 'book1', pages: 100 },
          { name: 'book2', pages: 200 },
          { name: 'book3', pages: 300 }
        ] }
      ).get('books[0]'), \
      { name: 'book1', pages: 100, is_long: false }

    assert_equal \
      has_list_class.books.build!.context(
        { books: [
          { name: 'book1', pages: 100 },
          { name: 'book2', pages: 200 },
          { name: 'book3', pages: 300 }
        ] }
      ).get('books[2,0]'), \
      [
        { name: 'book3', pages: 300, is_long: true },
        { name: 'book1', pages: 100, is_long: false }
      ]

    assert_equal \
      has_list_class.books.build!.context(
        { books: [
          { name: 'book1', pages: 100 },
          { name: 'book2', pages: 200 },
          { name: 'book3', pages: 300 }
        ] }
      ).get('books.name'), \
      %w[book1 book2 book3]

    assert_equal \
      has_list_class.books.build!.context(
        { books: [
          { name: 'book1', pages: 100 },
          { name: 'book2', pages: 200 },
          { name: 'book3', pages: 300 }
        ] }
      ).get('books[name,is_long]'), \
      [{ name: 'book1', is_long: false }, { name: 'book2', is_long: false },
       { name: 'book3', is_long: true }].map(&:compare_by_identity)
  end

  def test_query_object_props
    assert_equal @context.get('spaceship.total_power'), 300
    assert_equal @context.get('spaceship[volume]'), { volume: 52_500_000 }.compare_by_identity
    assert_equal @context.get('spaceship[crew[age,name],average_age]'),
                 {
                   crew: [
                     { age: 30, name: 'Alice' },
                     { age: 40, name: 'Bob' },
                     { age: 50, name: 'Steven' }
                   ].map(&:compare_by_identity),
                   average_age: 40
                 }.compare_by_identity
    assert_equal @context.get('spaceship[crew.position.salary,average_salary]'),
                 { crew: [100_000, 50_000, 20_000], average_salary: 56_666 }.compare_by_identity

    assert_equal @context.get('spaceship.crew.no_explicit_props'),
                 [{ hello: 1, world: 2, name: 'Alice' }, { hello: 1, world: 2, name: 'Bob' },
                  { hello: 1, world: 2, name: 'Steven' }]
  end

  def test_path_parser
    assert_equal LazyGraph::PathParser.parse('a.b.c'), %i[a b c]

    assert_equal LazyGraph::PathParser.parse('a.[b.c]'), [:a, [%i[b c]]]

    assert_equal LazyGraph::PathParser.parse('a.[b[c.d],e]'), [:a, [[:b, [%i[c d]]], [:e]]]
  end

  def test_module_merging
    graph_class = Class.new(LazyGraph::Builder) do
      rules_module :module_a do
        number :a, default: 1
        number :b, default: 2
      end

      rules_module :module_b do
        number :b, default: 3
        number :c, default: 4
      end

      rules_module :module_combined do
        depends_on :module_a, :module_b
        number :total, rule: '${a} + ${b} + ${c}'
      end
    end

    assert_equal graph_class.module_a.module_b.build!.context({}).b, 3
    assert_equal graph_class.module_b.module_a.build!.context({}).b, 2
    assert_equal graph_class.module_combined.build!.context({}).total, 8
  end

  def test_builder_group_api
    api = Object.const_set(:ExampleAPI, Module.new do
      const_set(:V1, Class.new(LazyGraph::Builder) do
        rules_module :stock do
          array :inventory do
            string :name
            number :price
          end
        end
      end)

      const_set(:V2, Class.new(LazyGraph::Builder) do
        rules_module :stock do
          array :inventory do
            string :name
            number :price
            number :quantity
          end
        end
      end)

      include LazyGraph::BuilderGroup.bootstrap!(reload_paths: [], enable_server: false)
    end)

    assert_equal api.rack_app.routes, { "/v1": ExampleAPI::V1, "/v2": ExampleAPI::V2 }.compare_by_identity

    LazyGraph.logger = Logger.new(nil)
    response = api.rack_app.call(
      {
        'REQUEST_METHOD' => 'POST',
        'PATH_INFO' => '/v1',
        'rack.input' => StringIO.new(
          {
            "modules": { "stock": {} },
            "debug": false,
            "context": {
              "inventory": [
                { "name": 'item1', "price": 1.0 }
              ]
            },
            "query": 'inventory'
          }.to_json
        )
      }
    )
    assert_equal response[0], 200
    assert_equal response[-1],
                 [{ 'type' => 'success',
                    'result' => { 'output' => [{ 'name' => 'item1', 'price' => 1.0 }] } }.to_json]
  end

  def test_context_get
    result = @context.get('')
    assert_equal result.class, LazyGraphCoreTest::SpaceshipBase::NodeProps
    assert_equal result.spaceship.components[0].attributes.volume, 10_500_000
    assert_equal result.spaceship.average_age, 40
  end

  def test_context_get_json
    result = @context.get_json('')
    assert_equal result.class, Hash
    assert_equal result[:spaceship][:crew][0], {
      name: 'Alice',
      age: 30,
      position_id: 1,
      position: {
        name: 'Captain',
        salary: 100_000
      },
      no_explicit_props: { hello: 1, world: 2, name: 'Alice' }
    }
  end

  def test_context_resolve
    result = @context.get_json('')
    assert_equal result.class, Hash
    assert result.key?(:spaceship)
  end

  def test_context_debug
    result = @context.debug('')
    assert result.is_a?(Array)
    assert_equal result[0], { output: :"$.spaceship.components[0].attributes.volume",
                              result: 10_500_000,
                              inputs: { weight: 1000, height: 100, depth: 105 },
                              calc: '${weight} * ${height} * ${depth}',
                              location: '$.spaceship.components[0].attributes' }
  end

  def test_hash_utils_deep_dup
    assert_equal LazyGraph::HashUtils.deep_dup({ a: { b: 1 } }), { a: { b: 1 } }
    refute LazyGraph::HashUtils.deep_dup({ a: { b: 1 } }).equal?({ a: { b: 1 } })
  end

  def test_deep_merge
    assert_equal LazyGraph::HashUtils.deep_merge({ a: { b: 1 } }, { a: { c: 2 } }), { a: { b: 1, c: 2 } }
  end

  def test_deep_merge_with_arrays
    assert_equal LazyGraph::HashUtils.deep_merge({ a: { b: [1] } }, { a: { b: [2] } }), { a: { b: [1, 2] } }
  end

  def test_strip_missing
    assert_equal LazyGraph::HashUtils.strip_missing({ a: 1, b: LazyGraph::MissingValue::BLANK }), { a: 1 }
  end

  def test_strip_missing_deep
    assert_equal LazyGraph::HashUtils.strip_missing({ a: 1, b: { c: LazyGraph::MissingValue::BLANK } }), { a: 1, b: {} }
  end

  def test_type_casting
    graph_with_casting = Class.new(LazyGraph::Builder) do
      rules_module :casting do
        decimal :decimal, default: 1.0
        date :date, default: '2021-01-01'
        time :time, default: '12:00:00'
        timestamp :timestamp, default: '2021-01-01T12:00:00'
      end
    end

    assert_equal graph_with_casting.casting.build!.context({ decimal: 1 }).decimal, 1.0.to_d
    assert_equal graph_with_casting.casting.build!.context({ decimal: '1' }).decimal, 1.0.to_d
    assert_equal graph_with_casting.casting.build!.context({ decimal: '3.43e-19' }).decimal, 0.343e-18
    assert_equal graph_with_casting.casting.build!.context({ date: '2021-01-01' }).date, Date.new(2021, 1, 1)
    assert_equal graph_with_casting.casting.build!.context({ timestamp: '2021-01-01T12:00:00' }).timestamp,
                 Time.at(1_609_502_400)
    assert_equal graph_with_casting.casting.build!.context({ time: '12:00:00' }).time, '12:00:00'
  end

  def test_scope_of_derived_rule_lambda
    graph_with_scope = Class.new(LazyGraph::Builder) do
      rules_module :scope do
        number :top_level
        object :grand_parent do
          string :name
          object :parent do
            string :name
            object :child do
              string :name
              array :ancestors, type: :string, rule: lambda {
                [itself.name, parent.name, grand_parent.name, top_level.to_s]
              }
            end
          end
        end
      end
    end

    assert_equal graph_with_scope.scope.build!.context(
      {
        top_level: 1,
        grand_parent: {
          name: 'grand',
          parent: { name: 'parent', child: { name: 'child' } }
        }
      }
    ).grand_parent.parent.child.ancestors,
                 %w[child parent grand 1]
  end

  def test_absolute_path
    graph_with_deep_children = Class.new(LazyGraph::Builder) do
      rules_module :deep_children do
        array :children do
          string :name
          array :children do
            string :name
            array :children do
              string :name
            end

            array :top_level_children, rule: '${$.children}'
            array :relative_children, rule: '${children}'
          end
        end
      end
    end
    result = graph_with_deep_children.deep_children.build!.context(
      {
        children: [
          { name: 'child1', children: [{ name: 'child1.1', children: [{ name: 'child1.1.1' }] }] },
          { name: 'child2', children: [{ name: 'child2.1', children: [{ name: 'child2.1.1' }] }] }
        ]
      }
    ).get('')

    first_child = result.children[0]
    first_grandchild = first_child.children[0]

    assert_equal first_grandchild.top_level_children, result.children
    assert_equal first_grandchild.relative_children, first_grandchild.children
  end

  # TODO: Resiliency tests
  # Meaningful error messages on:
  #   * Invalid derived inputs
  #   * Invalid match clauses
  #   * DSL in use without being inside a Rules module
end
