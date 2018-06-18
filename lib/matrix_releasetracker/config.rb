require 'psych'
require 'matrix_sdk'

module MatrixReleasetracker
  class Config
    def self.load!(filename = 'releasetracker.yml')
      config = Config.new filename
      config.load!
      config
    end

    attr_accessor :filename
    attr_reader :backends, :client, :media

    def load!
      raise 'Config file is missing' unless File.exist? filename

      data = Psych.load File.read(filename)

      @backends = Hash[data.fetch(:backends, []).map do |config|
        next unless config.key? :type
        type = config.delete(:type).to_s.downcase.to_sym

        backend = MatrixReleasetracker::Backends.constants.find { |c| c.to_s.downcase.to_sym == type }
        next if backend.nil?

        [type, MatrixReleasetracker::Backends.const_get(backend).new(config)]
      end]

      @client = [data.fetch(:client, {})].map do |config|
        MatrixSdk::Api.new config.delete(:hs_url), config
      end.first

      @media = data.fetch(:media, {})

      true
    end

    def save!
      File.write(
        filename,
        Psych.dump(
          backends: backends.map { |k, v| v.instance_variable_get(:@config).merge(type: k) },
          client: {
            hs_url: client.homeserver.to_s,
            access_token: client.access_token,
            device_id: client.device_id,
            validate_certificate: client.validate_certificate,
            transaction_id: client.instance_variable_get(:@transaction_id),
            backoff_time: client.instance_variable_get(:@backoff_time)
          },
          media: media
        )
      )
    end

    private

    def initialize(filename)
      @filename = filename

      @backends = {}
    end
  end
end