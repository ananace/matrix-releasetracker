module MatrixReleasetracker
  class Backend
    RateLimit = Struct.new('RateLimit', :backend, :requests, :remaining, :resets_at, :resets_in) do
      def near_limit
        remaining <= requests * 0.05
      end

      def to_s
        "#{backend.name}: Used #{requests - remaining}/#{requests} (#{(remaining / requests) * 100}%), resets in #{resets_in} seconds"
      end
    end

    def initialize(config)
      @config = config

      post_load
    end

    def post_load; end

    def post_update; end

    def name
      self.class.name.split(':').last
    end

    def users
      config[:users]
    end

    def last_releases(_user)
      raise NotImplementedException
    end

    protected

    attr_reader :config
  end

  module Backends
    autoload :Github, 'matrix_releasetracker/backends/github'
    autoload :Gitlab, 'matrix_releasetracker/backends/gitlab'
  end
end
