require 'psych'

module MatrixReleasetracker
  class Config
    def self.load!(filename = 'releasetracker.yaml')
      config = Config.new filename
      config.load!
      config
    end

    attr_accessor :filename
    attr_reader :backends

    def load!
      return true unless backends.nil?
      raise 'Config file is missing' unless File.exist? filename

      data = Psych.load File.read(filename)

      @backends = Hash[data.fetch(:backends, []).map do |config|
        next unless config.key? :type
        type = config.delete(:type).to_s.downcase.to_sym

        backend = MatrixReleasetracker::Backends.const_get(type.to_s.capitalize.to_sym)
        next if backend.nil?

        [type, config]
      end]

      true
    rescue StandardError => ex
      @backends = {}
      raise ex
    end

    def get_backend(backend)
      data = @backends.fetch(backend.to_s.downcase.to_sym)
      MatrixReleasetracker::Backends.const_get(backend.to_s.capitalize.to_sym).new data
    end

    private

    def initialize(filename)
      @filename = filename

      @backends = {}
    end
  end
end
