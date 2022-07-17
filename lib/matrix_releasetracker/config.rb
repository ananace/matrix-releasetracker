# frozen_string_literal: true

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
        MatrixReleasetracker::Client.new config: self, **config
      end.first

      db_config = {
        connection_string: 'sqlite://database.db',
        debug: false
      }.merge(data.fetch(:database, {}))
      @database = Database.new(db_config.delete(:connection_string), **db_config)

      @backends = data.fetch(:backends, []).to_h do |config|
        next unless config.key? :type

        type = config.delete(:type).to_s.downcase.to_sym

        backend = MatrixReleasetracker::Backends.constants.find { |c| c.to_s.downcase.to_sym == type }
        next if backend.nil?

        config[:database] = @database
        config[:client] = @client

        [type, MatrixReleasetracker::Backends.const_get(backend).new(config)]
      end

      @media = @database[:media]

      @client.reload!

      true
    end

    def save!
      client&.save!
    end

    private

    def initialize(filename)
      @filename = filename

      @backends = {}
    end
  end
end
