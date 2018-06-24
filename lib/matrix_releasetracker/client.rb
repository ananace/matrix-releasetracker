require 'json'
require 'matrix_sdk'

module MatrixReleasetracker
  class Client
    ACCOUNT_DATA_KEY = 'com.github.ananace.RequestTracker.data'.freeze

    attr_reader :api, :data

    def initialize(configuration)
      @api = MatrixSdk::Api.new configuration.delete(:hs_url), configuration
      @data = {}

      begin
        api.whoami? # TODO: @api.logged_in?
        reload!

        data[:next_batch] = configuration.delete :next_batch if configuration.key? :next_batch
      rescue MatrixSdk::MatrixRequestError => ex
        raise ex if ex.httpstatus != 401
      end
    end

    def next_batch
      data[:next_batch]
    end

    def next_batch=(batch)
      data[:next_batch] = batch
    end

    def reload!
      @data = [api.sync(timeout: 5.0, set_presence: :offline)].map do |data|
        data = data[:account_data][:events].find { |ev| ev[:type] == ACCOUNT_DATA_KEY }
        (data[:content] if data) || {}
      end.first

      true
    end

    def save!
      api.set_account_data(api.whoami?[:user_id], ACCOUNT_DATA_KEY, @data)

      true
    end
  end
end
