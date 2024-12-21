module LazyGraph
  module Environment
    def self.development? = env == 'development'
    def self.env = ENV.fetch('RACK_ENV', 'development')
  end
end
