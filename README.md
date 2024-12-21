<table>
  <tr>
    <td><img src="./logo.png" alt="logo" width="150"></td>
    <td>
      <h1 align="center">LazyGraph</h1>
      <p align="center">
        <a href="https://rubygems.org/gems/lazy_graph">
          <img alt="GEM Version" src="https://img.shields.io/gem/v/lazy_graph?color=168AFE&include_prereleases&logo=ruby&logoColor=FE1616">
        </a><br>
        <a href="https://rubygems.org/gems/lazy_graph">
          <img alt="GEM Downloads" src="https://img.shields.io/gem/dt/lazy_graph?color=168AFE&logo=ruby&logoColor=FE1616">
        </a>
      </p>
    </td>
  </tr>
</table>

# LazyGraph

<details>
  <summary><strong>Table of Contents</strong></summary>

1. [Introduction](#introduction)
2. [Features](#features)
3. [Installation](#installation)
4. [Getting Started](#getting-started)
   - [Defining a Schema](#defining-a-schema)
   - [Providing Input](#providing-input)
   - [Querying the Graph](#querying-the-graph)
5. [Advanced Usage](#advanced-usage)
   - [Builder DSL](#builder-dsl)
   - [Derived Properties and Dependency Resolution](#derived-properties-and-dependency-resolution)
   - [Debug Mode & Recursive Dependency Detection](#debug-mode--recursive-dependency-detection)
   - [Advanced Path Syntax](#advanced-path-syntax)
   - [LazyGraph Server](#lazygraph-server)
6. [API Reference and Helpers](#api-reference-and-helpers)
7. [Contributing](#contributing)
8. [License](#license)

</details>

## Introduction

**LazyGraph** is an ideal tool for building efficient rules engines. It comes with optional batteries included for
exposing these engines as stateless HTTP services, using an opinionated set of defaults.

Unlike traditional rules engines, which utilize facts to manipulate stateful memory,
LazyGraph encodes rules into a stateless, declarative domain graph.

A LazyGraph is similar to a limited [**JSON Schema**](https://json-schema.org/), allowing a single structure
to define both the shape of your domain data, and all of the rules that should operate within it.

To use it, you:

1. Define a **JSON Schema-like** structure describing how data in your domain is structured, containing required, optional and derived properties.
   - **Rules**: All properties that can be computed are marked with a `rule` property, which defines how to compute the value in plain old Ruby code.
     The rule can reference other properties in the schema as dependencies, allowing for complex, nested, and recursive computations.

2. Feed an **input document** (JSON) that partially fills out the schema with actual data.

3. Query the `LazyGraph` for computed outputs.

`LazyGraph` will:
* Validate that the input conforms to the schema’s structure and then
* Allow you to intelligently query the graph for information, lazily triggering the evaluation of rules as required to respond to the query (resolving dependencies in a single pass and caching results).

The final output is the queried slice of your JSON schema, filled with computed outputs.

The `LazyGraph` library also includes:

- A **Builder DSL** to dynamically compose targeted JSON Schemas in Ruby.
- An optional **HTTP server** to serve dynamic computations from a simple set of auto-generated stateless endpoints, no additional code required!.

## Elevator Pitch

```ruby
require 'lazy_graph'

module ShoppingCartTotals
  module API
    # We're using the higher-level builder API here,
    # but you can also define your graph using JSON or plain-old hashes and arrays.
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
```

With just the above, we've defined a set of rules for computing shopping cart totals.

We can now:
* Invoke this module directly from Ruby code, e.g.

```ruby
ShoppingCartTotals::API::V1.cart.eval!({
    "items": [
        {"quantity": 2, "price": 200},
        {"quantity": 2, "price": 5}
    ],
    "applied_coupon": "15%OVER100"
}).get('[total,net,discount]')

# => {total: 383.35, net: 348.5, discount: 61.5}
```
Or:

* Expose this same service via an efficient, stateless HTTP API
e.g.

```bash
$ bundle exec ruby shopping_cart_totals.rb
Starting single-process server on port 9292...
[PID 67702] Listening on port 9292...
```

```bash
$ RACK_ENV=production bundle exec ruby shopping_cart_totals.rb
Starting Raxx server with 8 processes on port 9292...
[PID 67791] Listening on port 9292...
[PID 67792] Listening on port 9292...
[PID 67793] Listening on port 9292...
[PID 67794] Listening on port 9292...
[PID 67795] Listening on port 9292...
[PID 67796] Listening on port 9292...
[PID 67797] Listening on port 9292...
[PID 67799] Listening on port 9292...
```

```bash
$ curl http://localhost:9292/api/v1 -XPOST -d '{
  "modules": "cart",
  "context": {
    "items": [
        {"quantity": 2, "price": 200},
        {"quantity": 2, "price": 5}
    ],
    "applied_coupon": "15%OVER100"
  }
}' | jq

{
  "type": "success",
  "result": {
    "output": {
      "items": [
        {
          "quantity": 2,
          "price": 200,
          "unit_total": 400
        },
        {
          "quantity": 2,
          "price": 5,
          "unit_total": 10
        }
      ],
      "applied_coupon": "15%OVER100",
      "gross": 410,
      "discount": 61.5,
      "net": 348.5,
      "gst": 34.85,
      "total": 383.35
    }
  }
}

```

Or if you pass `"debug": true`

```json
{
  ...
  "debug_trace": [
  {
    "output": "$.items[0].unit_total",
    "result": 400,
    "inputs": {
      "quantity": 2,
      "price": 200
    },
    "calc": "${quantity} * ${price}",
    "location": "$.items[0]"
  },
  {
    "output": "$.items[1].unit_total",
    "result": 10,
    "inputs": {
      "quantity": 2,
      "price": 5
    },
    "calc": "${quantity} * ${price}",
    "location": "$.items[1]"
  },
  {
    "output": "$.coupon_codes",
    "result": {
      "10OFF": {
        "discount_abs": 10
      },
      "15%OVER100": {
        "discount_percent": 15,
        "min_total": 100
      },
      "20%OVER200": {
        "discount_percent": 20,
        "min_total": 200
      }
    },
    "inputs": {},
    "calc": "valid_coupons",
    "location": "$"
  },
  {
    "output": "$.gross",
    "result": 410,
    "inputs": {
      "items.unit_total": [
        400,
        10
      ]
    },
    "calc": "${items.unit_total}.sum",
    "location": "$"
  },
  {
    "output": "$.discount",
    "result": 61.5,
    "inputs": {
      "coupon_codes[applied_coupon]": {
        "discount_percent": 15,
        "min_total": 100
      },
      "gross": 410
    },
    "calc": "apply_coupon_code(${coupon_codes[applied_coupon]}, ${gross})",
    "location": "$"
  },
  {
    "output": "$.net",
    "result": 348.5,
    "inputs": {
      "gross": 410,
      "discount": 61.5
    },
    "calc": "${gross} - ${discount}",
    "location": "$"
  },
  {
    "output": "$.gst",
    "result": 34.85,
    "inputs": {
      "net": 348.5
    },
    "calc": "(${net} * 0.1).round(2)",
    "location": "$"
  },
  {
    "output": "$.total",
    "result": 383.35,
    "inputs": {
      "net": 348.5,
      "gst": 34.85
    },
    "calc": "${net} + ${gst}",
    "location": "$"
  }]
}
```

The above showcases a selection of some of the most compelling features of LazyGraph in a simple single-file implementation, but there's much more to see.

Read on to learn more...

## Features

- **Lazy Evaluation & Caching**
  Derived fields are efficiently calculated, at-most-once, on-demand.

- **Recursive Dependency Check**
  Automatically detects cycles in your derived fields and logs warnings/debug info if recursion is found.

- **Debug Trace**
  The order in which recursive calculations are processed is not always obvious.
  LazyGraph is able to provide a detailed trace of exactly, when and how each value was computed.
  Output from LazyGraph is transparent and traceable.

- **Rich Querying Syntax**
  Extract exactly what you need from your model with an intuitive path-like syntax. Support for nested properties, arrays, indexing, ranges, wildcards, and more.

- **Composable Builder DSL**
  Support dynamic creation of large, composable schemas in Ruby with a simplified syntax.

- **Optional HTTP Server**
  Spin up an efficient server that exposes several dynamic lazy-graphs as endpoints, allowing you to:
    * Select a dynamic schema
    * Feed in inputs and a query
    * Receive the computed JSON output
  all at lightning speed.

## Installation

Add this line to your application’s Gemfile:

```ruby
gem 'lazy_graph'
```

And then execute:

```bash
bundle
```

Or install it yourself:

```bash
gem install lazy_graph
```

## Getting Started

In this section, we’ll explore how to set up a minimal LazyGraph use case:

1. **Define** a JSON Schema (with LazyGraph’s extended properties and types).
2. **Provide** an input document.
3. **Query** the graph to retrieve computed data.

### Defining a Schema

A LazyGraph schema looks like a standard JSON Schema, you can build LazyGraph schemas
efficiently using the builder DSL, but can just as easily define one from a plain-old Ruby hash.

There are a few key differences between a JSON schema and a LazyGraph schema:

* The `rule` property, which defines how to compute derived fields.
  - `rule:`
    Defines a rule that computes this property’s value, if not given, referencing other fields in the graph.

* The schema also *does not* support computation across node types of `oneOf`, `allOf`, `anyOf`, `not`, or references
(read examples for alternative mechanisms for achieving similar flexibility in your live schema)

Any field (even object and array fields) can have a `rule` property.

Values at this property are lazily computed, according the rule, if not present in the input.
However, if the value is present in the input, the rule is not triggered, which makes a LazyGraph highly flexible as
you can override *absolutely any* computed step or input in a complex computation graph, if you choose.

Here’s a simple **shopping cart** example:

```ruby
require 'lazy_graph'

cart_schema = {
  type: 'object',
  properties: {
    cart: {
      type: 'object',
      properties: {
        items: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              name: {
                type: 'string'
              },
              price: {
                type: 'number',
                default: 1.0
              },
              quantity: {
                type: 'number',
                default: 1
              },
              total: {
                type: 'number',
                rule: '${price} * ${quantity}'
              }
            }
          },
          required: ['name']
        },
        cart_total: {
          type: 'number',
          rule: {
            inputs: {item_totals: 'items.total'},
            calc: 'item_totals.sum'
          }
        }
      }
    }
  }
}

cart_graph = cart_schema.to_lazy_graph
```

### Providing Input

Once you've defined a `LazyGraph`, you should feed it an **input document** that partially fills out the schema. For instance:

```ruby
input_data = {
  cart: {
    items: [
      { name: 'Widget', price: 5.0, quantity: 2 },
      { name: 'Gadget' }
    ]
  }
}
```

- `Widget` is fully specified with `price=5.0` and `quantity=2`.
- `Gadget` is missing `price` and `quantity`, so it will use defaults (`1.0` for price and `1` for quantity).

### Querying the Graph

Then, to compute derived fields and extract results, we can query our lazy graph instance, to efficiently
resolve subsections of the graph (or just resolve the whole thing!).

```ruby
# Create the graph and run the query:
graph_context = cart_graph.context(input_data)

# If we query '' (empty string), we get the entire graph with computed values:
whole_output = graph_context['']
puts JSON.pretty_generate whole_output
# {
#   "output": {
#     "cart": {
#       "items": [
#         {
#           "name": "Widget",
#           "price": 5.0,
#           "quantity": 2,
#           "total": 10.0
#         },
#         {
#           "name": "Gadget",
#           "price": 1.0,
#           "quantity": 1,
#           "total": 1.0
#         }
#       ],
#       "cart_total": 11.0
#     }
#   },
#   "debug_trace": null
# }

# Query a specific path, e.g. "cart.items[0].total"
graph_context.get("cart.items.total")
# => 10.0

# e.g. "cart.items.total"
graph_context.resolve("cart.items.total")
# => {output: [10.0, 1.0], debug_trace: nil}


# e.g. "cart.items[name, total]"
all_item_name_and_totals = graph_context["cart.items[name, total]"]
# => {output: [{name: "Widget", total: 10.0}, {name: "Gadget", total: 1.0}], debug_trace: nil}
```

LazyGraph **recursively computes** any derived fields, referenced in the query.
If you query only a subset of the graph, only the necessary computations are triggered, allowing for very fast responses,
even on graphs with millions of interdependent nodes.

### Validating input data
LazyGraph inherits much of the JSON Schema validation capabilities, and will validate the input data against the schema before attempting to compute any derived fields.
Overtop of this, you can add additional validation, directly within your rules.
If code within a rule encounters an unrecoverable error, it is free to raise, which will return a missing value in the output for this node and add
detailed debug information to the debug log. If, however, the error is severe enough to warrant stopping all further computation you can raise either a:

* LazyGraph::AbortError - For aborting the entire resolution process
* LazyGraph::ValidationError - As above, *but* with added semantic meaning, that the specific failure is a validation one.

## Advanced Usage

### Builder DSL

Rather than manually writing JSON schemas, LazyGraph also offers a **Ruby DSL** for building them.
This is useful if your schema needs to be dynamic (variable based on inputs), has repeated patterns, or is built across multiple modules,
which you wish to allow a user to combine in different ways.

```ruby
module ShoppingCart
  class CartBuilder < LazyGraph::Builder
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
end

# Then we can build a cart schema, feed input, and query:
cart_schema = ShoppingCart::CartBuilder.cart_base
context = cart_schema.feed({
  cart: {
    items: [
      { name: 'Widget', price: 10.0, quantity: 2 },
      { name: 'Thingamajig' }
    ]
  }
})

puts context['cart.cart_total'] # => 21.0
```

We can create any number of modules within a builder, and then merge them together in any combination to create a final schema.
E.g.

```ruby
# A second module that can be merged into the schema
rules_module :stock do
  object :stock do
    number :available, default: 100
    number :reserved, default: 0
    number :total, rule: '${available} - ${reserved}'
  end
end
```

You can easily merge these, by chaining module builder calls.
This merging capability is particularly powerful if you have a very large business domain with many overlapping concerns.
You can allow the caller to dynamically compose and query any combination of these sub-domains, as required.

```ruby
# Combine two modules
cart_schema = ShoppingCart::CartBuilder.cart_base.stock.build! # (also accepts optional args like :debug and :validate)

# Use just a single module
cart_schema = ShoppingCart::CartBuilder.cart_base.build!
```

### Rules and Dependency Resolution

Rules let you define logic for computing new values from existing ones. LazyGraph:

1. Gathers each property’s **dependencies** (in the example, `total` depends on `price` and `quantity`).
2. Computes them **on-demand**, in a topological order, ensuring that any fields they rely on are already resolved.
3. Caches the results so subsequent references don’t trigger re-computation.

This graph-based approach means you can nest derived fields deeply without worrying about explicit ordering. If a derived field depends on another derived field, LazyGraph naturally handles the chain.

#### Derived Rules DSL
There are several different ways to define Rules in a LazyGraph.
The most portable way (using plain old JSON) is to define a rule as a string that references other properties in the schema using
${} placeholder syntax.

##### Simple inline rules
E.g.

```ruby
rule: :'${price} * ${quantity}'
```

You can define the inputs separately from the calculation, which can be useful for more complex rules:

As an array if you do not need to map paths
```ruby
rule: {
  inputs: %[quantity],
  calc: :'quantity.sum'
}
```

As a hash of input names to resolution paths
```ruby
rule: {
  inputs: {item_totals: 'items.total'},
  calc: 'item_totals.sum'
}
```

##### Block Rules
The most expressive way to define rules is to use a Ruby block, proc or lambda.
This is also the recommended approach for any rules that are more than a simple expression.

The arguments to the block are *automatically* resolved and fed as inputs into the block.
You can use keyword arguments to map paths to the input names (only necessary if the input name differs from the resolved input path)

```ruby
# The input price is resolved to the value at path: 'price'
# The input quantity is resolved to the value at path:  'quantity'
# The input store_details is resolved to the value at path: 'store.details'
rule: ->(price, quantity, store_details: store.details) {
  price * quantity * store_details.discount
}
```

*Note:* Block rules *cannot* be defined from inside a REPL, as LazyGraph needs to read and interpret these blocks from the source code
on the filesystem to be able to perform resolution and to include the original source code inside debug outputs.

Resolution is performed relative to the current node.

I.e. it will look for the path in the current node, and then in the parent node, and so on, until it finds a match.
If you wish to make an absolute reference, you can prefix the path with a `$` to indicate that it should start at the root of the schema.
Note, inside lambda rules, absolute references begin with a _ instead.

E.g.
```ruby
rule: ->(store_details: _.store.details) {
  store_details.discount * price * quantity
}
```

Within the body of a rule, a full binding/context stack is populated, from the current node up to the root node
and used for resolution of any variables.
This means that within a rule you exist "within" the graph, and are able to freely access any other node in the computation graph.

Just type a variable by name and it will automatically be recursively resolved to the correct value.

*However* it is essential that you explicitly define all inputs to the rule to ensure resolution is correct,
as LazyGraph will not automatically resolve any variables that are dynamically accessed, meaning any variables that are
generated by rules may *not yet* have been populated when accessed from within a rule, unless it's been explicitly indicated as dependency.

This is advanced functionality, and should be used with caution. In general, it is best to define all input dependencies explicitly.
You can put a breakpoint inside a lambda rule to inspect the current scope and understand what is available to you.
Check out:

- `stack_ptr` - The current stack pointer, which is the current node in the graph.
- `stack_ptr.parent` - The parent node in the graph (you can traverse up the graph by following the parent pointers).
- `stack_ptr.key` - The key in the parent node where the current node is stored (e.g. an index in an array or property name)
- `stack_ptr.frame` - The current frame in the graph, which contains actual graph data.
- `itself` - The current node in the graph (same as stack_ptr.frame)

### Debug Mode & Recursive Dependency Detection

If you pass `debug: true`, the output will also contain an "output_trace" array,
containing a detailed, ordered log of how each derived field was computed (inputs, calc and outputs).

```ruby
cart_builder = ShoppingCart::CartBuilder.cart_base
context = cart_builder.feed({
  cart: {
    items: [
      { name: 'Widget', price: 10.0, quantity: 2 },
      { name: 'Thingamajig' }
    ]
  }
}, debug: true)

# Get debug output
context.debug("cart.cart_total")
# =>
# [{output: :"$.cart.items[0].total", result: 20.0, inputs: {price: 10.0, quantity: 2}, calc: "${price} * ${quantity}", location: "$.cart.items[0]"},
#  {output: :"$.cart.items[1].total", result: 1.0, inputs: {price: 1.0, quantity: 1}, calc: "${price} * ${quantity}", location: "$.cart.items[1]"},
#  {output: :"$.cart.cart_total", result: 21.0, inputs: {"items.total": [20.0, 1.0]}, calc: "${items.total}.sum", location: "$.cart"}]

# Alternatively, use #resolve to get a hash with both :output and :debug_trace keys populated
context.resolve("cart.cart_total")

#  context.resolve("cart.cart_total")
# =>
# {output: 21.0,
# debug_trace:
#  [{output: :"$.cart.items[0].total", result: 20.0, inputs: {price: 10.0, quantity: 2}, calc: "${price} * ${quantity}", location: "$.cart.items[0]"},
#   {output: :"$.cart.items[1].total", result: 1.0, inputs: {price: 1.0, quantity: 1}, calc: "${price} * ${quantity}", location: "$.cart.items[1]"},
#   {output: :"$.cart.cart_total", result: 21.0, inputs: {"items.total": [20.0, 1.0]}, calc: "${items.total}.sum", location: "$.cart"}]}
```

In cases where you accidentally create **circular dependencies**, LazyGraph will log warnings to the debug logs, and detect and break infinite loops
in the dependency resolution, ensuring that the remainder of the graph is still computed correctly.

### Conditional Sub-Graphs

Nodes within a graph, can be conditionally evaluated, based on properties elsewhere in the graph.
This can help you avoid excessive computation, and support polymorphism in outputs.
To use this functionality within the Builder dsl, use the #object_conditional helper.

E.g.

```ruby
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

```

```bash
$ bundle exec ruby converter.rb
# [PID 91560] Listening on port 9292...

$ curl -XPOST http://localhost:9292/rgb -d '{
  "modules": "rgb_converter",
  "query": "color.rgb",
  "context": {
    "mode": "hsl",
    "h": 100,
    "s": 0.2,
    "l": 0.5
  }
}' | jq

# {
#  "type": "success",
#  "result": {
#    "output": [
#      127.5,
#      153.0,
#      102.0
#    ]
#  }
#}
```


### Advanced Path Syntax

LazyGraph’s query engine supports a flexible path notation:

- **Nested properties**: `"cart.items[0].total"`, `"cart.items[*].name"`, etc.
- **Object bracket expansions**: If a property is enclosed in `[keyName]`, the key and value are kept together when extracting partial JSON. For example, `"cart[items]"` yields `{"cart"=>{"items"=>[...]}}`.
- **Array indexing**: `"items[0]"`, `"items[0..2]"`, `"items[*]"` (all items), or `"items[0, 2, 4]"` for picking multiple indexes.
- **Ranged queries**: `"items[1..3]"` returns a slice from index 1 to 3 inclusive.
- **Root Queries**: 'Useful inside rules for dependencies that are not relative to the current node. E.g. `"$.cart.items[0].total"` (or `_.cart.items[0].total` inside proc rules).

### LazyGraph Server

For situations where you want to serve rules over HTTP:

1. **Define** your schema(s) with the DSL or standard JSON approach.
2. **Implement** a small server that:
   - Instantiates the schema.
   - Takes JSON input from a request.
   - Runs a query (passed via a query parameter or request body).
   - Returns the computed JSON object.

A minimal example might look like:

```ruby
require 'lazy_graph'

module CartAPI
  VERSION = '0.1.0'

  # Add all classes that you want to expose in the API, as constants to the builder group module.
  # These will turn into downcased, nested endpoints.
  # E.g.
  # /cart/v1
  # - GET: Get module info
  # - POST: Run a query
  #   Inputs: A JSON object with the following keys:
  #
  #    - modules: { cart: {} } # The modules to merged into the combined schema,
  #                            # you can pass multiple modules here to merge them into a single schema.
                               # The keys inside each module object, are passed as arguments to the rules_module dsl method
                               # to allow you to dynamically adjust your output schema based on API inputs.
  #    - query: "cart.cart_total" # The query to run. Can be a string, an array of strings or empty (in which case entire graph is returned)
  #    - context: { cart: { items: [ { name: "Widget", price: 2.5, quantity: 4 } ] } } # The input data to the schema
  module Cart
    class V1 < LazyGraph::Builder

      # A module that can be merged into the schema
      rules_module :cart_base do |foo:, bar:|
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

      # A second module that can be merged into the schema
      rules_module :stock do
        object :stock do
          number :available, default: 100
          number :reserved, default: 0
          number :total, rule: '${available} - ${reserved}'
        end
      end
    end
  end

  # Bootstrap our builder group.
  include LazyGraph.bootstrap_app!
end
```

Then send requests like:

```bash
curl -X POST http://localhost:9292/cart/v1 \
  -H 'Content-Type: application/json' \
  -d '{
    "modules": ["cart", "stock"],
    "query": "cart.cart_total",
    "context": {
      "cart": {
        "items": [
          { "name": "Widget", "price": 2.5, "quantity": 4 }
        ]
      }
    }
  }'
```

Response:

```json
{
  "type": "success",
  "result": {
    "output": 10.0
  }
}
```
#### Note on Security
The LazyGraph server does not implement any authorization or authentication. In its basic form, it is intended purely as a backend service for your application
**LazyGraph server should not be allowed to accept untrusted inputs**, especially considering that default and computed values at arbitrary nodes can be overridden by fixed values in the input context.


## Where LazyGraph Fits

If you’re coming from a background in any of the following technologies, you might find several familiar ideas reflected in LazyGraph:

* *Excel*: Formulas in spreadsheets operate similarly to derived fields—they reference other cells (properties) and recalculate automatically when dependencies change.
LazyGraph extends that principle to hierarchical or deeply nested data, making it easier to manage complex relationships than typical flat spreadsheet cells.
*	*Terraform*: Terraform is all about declarative configuration and automatic dependency resolution for infrastructure.
LazyGraph brings a similar ethos to your application data—you declare how fields depend on one another, and the engine takes care of resolving values in the correct order, even across multiple modules or partial inputs.
*	*JSON Schema*: At its core, LazyGraph consumes standard JSON Schema features (type checks, required fields, etc.) but introduces extended semantics (like derived or default).
If you’re already comfortable with JSON Schema, you’ll find the basic structure familiar—just expanded to support making your data dynamic and reactive.
*	*Rules Engines* / Expert Systems: Traditional rule engines (like Drools or other Rete-based systems) let you define sets of conditional statements that trigger when facts change.
In many scenarios, LazyGraph can serve as a lighter-weight alternative: each “rule” (i.e., derived property) is defined right where you need it in the schema, pulling its dependencies from anywhere else in the data. You get transparent, on-demand evaluation without the overhead of an external rules engine. Plus, debug traces show exactly how each value was computed, so there’s no confusion about which rules fired or in which order.
*	*JSON* Path, GraphQL, jq: These tools are great for querying JSON data, but they don't handle automatic lazy dependency resolution.
LazyGraph’s querying syntax is designed to be expressive and powerful, allowing you to extract the data you need (triggering only the required calculations) from a complex graph of computed values.

### Typical Use Cases
You can leverage these concepts in a variety of scenarios:
* Rules Engines: Encode complex, nested and interdepdendent rules into a single, easy to reason about, JSON schema.
* Complex Chained Computation: Where multiple interdependent properties (e.g. finance calculations, policy checks) must auto-update when a single input changes.
* Dynamic Configuration: Generate derived settings based on partial overrides without duplicating business logic everywhere.
* Form or Wizard-Like Data: Reactively compute new fields as users provide partial inputs; only relevant properties are evaluated.
* Stateless Microservices / APIs: Provide an HTTP endpoint that accepts partial data, automatically fills in defaults and computed fields, and returns a fully resolved JSON object.

## API Reference and Helpers

For more fine-grained integration without the DSL or server, you can use the lower-level Ruby API entry points:

E.g. where `my_schema` is a LazyGraph compliant JSON Schema:

```ruby
# 1. Turn the schema hash into a lazy graph. (From which you can generate contexts)
graph = my_schema.to_lazy_graph() # Optional args debug: false, validate: true

# 2. Immediately create a context from the graph and input data.
ctx = my_schema.to_graph_ctx(input_hash) # Optional args debug: false, validate: true

# 3. Immediately evaluate a query on context given the graph and input data.
result = my_schema.eval!(input_hash, 'some.query') # Optional args debug: false, validate: true
```

These methods allow you to embed LazyGraph with minimal overhead if you already have your own project structure.

## Contributing

Bug reports and pull requests are welcome on GitHub at [https://github.com/wouterken/lazy_graph](https://github.com/wouterken/lazy_graph). This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to follow our [code of conduct](./CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
