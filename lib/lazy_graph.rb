# frozen_string_literal: true

# LazyGraph is a library which allows you to define a strictly typed hierarchical Graph structure.
# Within this graph you can annotate certain nodes as derived nodes, which compute their outputs based
# on input dependencies on other nodes in the graph structure (can be relative and absolute references).
# Dependencies can be nested any level deep (but cannot be circular).
#
# You can then provide a subset of the graph as input context, and extract calculated outputs from the same graph
# which will be lazily computed (only derived rules actually needed for the queried output is computed).
#
module LazyGraph
  class AbortError < StandardError; end
  class ValidationError < StandardError; end
end

require_relative 'lazy_graph/context'
require_relative 'lazy_graph/missing_value'
require_relative 'lazy_graph/node'
require_relative 'lazy_graph/graph'
require_relative 'lazy_graph/version'
require_relative 'lazy_graph/path_parser'
require_relative 'lazy_graph/hash_utils'
require_relative 'lazy_graph/builder'
require_relative 'lazy_graph/builder_group'
require_relative 'lazy_graph/stack_pointer'
require_relative 'lazy_graph/cli'
require_relative 'lazy_graph/rack_server'
require_relative 'lazy_graph/rack_app'
require_relative 'lazy_graph/logger'
require_relative 'lazy_graph/environment'
