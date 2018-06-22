module MatrixReleasetracker::Backends
  class Github < MatrixReleasetracker::Backend

    def logger
      Logging.logger[self.class.name]
    end

    def name
      'GitLab'
    end

    def rate_limit
      RateLimit.new(self, 0, 0, Time.now, 0)
    end

    def all_stars(data = {})
      []
    end

    def stars(user, data = {})
      []
    end

    def latest_release(repo, data = {})
      nil
    end

    def latest_releases(user)
      []
    end

    private

    def client
      @client ||= nil
    end
  end
end

