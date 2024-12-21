module LazyGraph
  class BuilderGroup
    # A builder group is simply a named colleciton of builders (each a subclass of LazyGraph::Builder)
    # That can be reloaded in bulk, and exposed via a simple HTTP server interface.
    # If a script file defining a builder group is run directly, it will start a Puma server
    # to host itself
    def self.bootstrap!(reload_paths: nil, exclude_paths: [], listen: Environment.development?, enable_server: true)
      bootstrap_script_name = caller.drop_while { |r| r =~ /builder_group/ }[0][/[^:]+/]
      reload_paths ||= File.join(File.dirname(bootstrap_script_name), '**/*.rb')
      reload_paths = Array(reload_paths)

      Module.new do
        define_singleton_method(:included) do |base|
          def base.each_builder(const = self, &blk)
            return to_enum(__method__, const) unless blk

            if const.is_a?(Class) && const < LazyGraph::Builder
              blk[const]
            elsif const.is_a?(Module)
              const.constants.each do |c|
                each_builder(const.const_get(c), &blk)
              end
            end
          end

          def base.rack_app(**opts)
            unless defined?(Rack)
              raise AbortError,
                    'You must install rack first to be able to run a LazyGraph BuilderGroup as a server'
            end

            LazyGraph::RackApp.new(
              routes: each_builder.map do |builder|
                [
                  builder.to_s.downcase.gsub('::', '/').gsub(/^#{name.to_s.downcase}/, ''),
                  builder
                ]
              end.to_h,
              **opts
            )
          end

          base.define_singleton_method(:reload_lazy_graphs!) do |clear_previous: false|
            each_builder(&:clear_caches!) if clear_previous

            reload_paths.flat_map { |p|
              Dir[p]
            }.-([bootstrap_script_name]).sort_by { |file| file.count(File::SEPARATOR) }.each do |file|
              load file unless exclude_paths.any? { |p| p =~ file }
            rescue StandardError => e
              LazyGraph.logger.error("Failed to load #{file}: #{e.message}")
            end
          end

          base.reload_lazy_graphs! if reload_paths.any?

          if listen && defined?(Listen)
            Listen.to(*reload_paths.map { |p| p.gsub(%r{(?:/\*\*)*/\*\.rb}, '') }) do
              base.reload_lazy_graphs!(clear_previous: true)
            end.start
          end

          CLI.invoke!(base.rack_app) if enable_server && bootstrap_script_name == $0
        end
      end
    end
  end

  define_singleton_method(:bootstrap_app!, &BuilderGroup.method(:bootstrap!))
end
