module MatrixReleasetracker
  class Backend
    def initialize(config)
      @config = config
    end

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
  end
end
