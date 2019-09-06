require 'matrix_releasetracker/version'
require 'matrix_releasetracker/backend'
require 'matrix_releasetracker/client'
require 'matrix_releasetracker/config'
require 'matrix_releasetracker/release'
require 'matrix_releasetracker/structs'

module MatrixReleasetracker
  module Backends
    autoload :Github, 'matrix_releasetracker/backends/github'
    autoload :Gitlab, 'matrix_releasetracker/backends/gitlab'
  end
end
