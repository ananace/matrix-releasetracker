require 'psych'

module MatrixReleasetracker
  class Config
    def self.load!(filename = 'releasetracker.yml')
      config = Config.new filename
      config.load!
      config
    end

    attr_accessor :filename
    attr_reader :backends, :client, :media, :database

    def load!
      raise 'Config file is missing' unless File.exist? filename

      data = Psych.load File.read(filename)

      @client = [data.fetch(:client, {})].map do |config|
        MatrixReleasetracker::Client.new config
      end.first

      @database = Database.new([data.fetch(:database, {})].map do |config|
        config[:connection_string]
      end.first || 'sqlite://database.db')

      @backends = Hash[data.fetch(:backends, []).map do |config|
        next unless config.key? :type
        type = config.delete(:type).to_s.downcase.to_sym

        backend = MatrixReleasetracker::Backends.constants.find { |c| c.to_s.downcase.to_sym == type }
        next if backend.nil?

        config[:database] = @database

        [type, MatrixReleasetracker::Backends.const_get(backend).new(config, @client)]
      end]

      @media = @database[:media]

      true
    end

    def save!
      client.save! if client
    end

    private

    def initialize(filename)
      @filename = filename

      @backends = {}
    end
  end
end
