require 'matrix_releasetracker/version'
require 'matrix_releasetracker/backend'
require 'matrix_releasetracker/client'
require 'matrix_releasetracker/config'
require 'matrix_releasetracker/database'
require 'matrix_releasetracker/release'
require 'matrix_releasetracker/structs'

module MatrixReleasetracker
  module Backends
    autoload :Gitea,  'matrix_releasetracker/backends/gitea'
    autoload :Github, 'matrix_releasetracker/backends/github'
    autoload :Gitlab, 'matrix_releasetracker/backends/gitlab'
  end

  def self.logger
    @logger ||= Logging.logger[MatrixReleasetracker].tap do |log|
      log.add_appenders Logging.appenders.stdout(
        layout: Logging::Layouts.pattern(pattern: "[%d|%.1l] %c: %m\n", date_pattern: '%F %T')
      )
    end
  end

  def self.debug!
    logger.level = :debug
  end
end
