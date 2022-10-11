# frozen_string_literal: true

require 'test_helper'

class ClientTest < Minitest::Test
  def setup
    @client = MatrixReleasetracker::Client.new config: nil, hs_url: 'http://localhost'
  end

  def test_tracking_parsing
    tests = {
      'github:u/user' => { backend: :github, type: :user, object: 'user' },
      'github:g/group' => { backend: :github, type: :group, object: 'group' },
      'github:r/group/repo' => { backend: :github, type: :repository, object: 'group/repo' },
      'github:r/group/repo?allow=tag' => { backend: :github, type: :repository, object: 'group/repo', data: { allow: ['tag'] } },
      'gitlab:u/user' => { backend: :gitlab, type: :user, object: 'user' },
      'gitlab:g/group' => { backend: :gitlab, type: :group, object: 'group' },
      'gitlab:r/group/repo' => { backend: :gitlab, type: :repository, object: 'group/repo' },
      'gitlab:token@u/user' => { backend: :gitlab, type: :user, object: 'user', data: { token: 'token' } },
      'gitlab:token@g/group' => { backend: :gitlab, type: :group, object: 'group', data: { token: 'token' } },
      'gitlab:token@r/group/repo' => { backend: :gitlab, type: :repository, object: 'group/repo', data: { token: 'token' } },
      'gitlab://gitlab.example.com/u/user' => { backend: :gitlab, type: :user, object: 'gitlab.example.com:user' },
      'gitlab://gitlab.example.com/g/group' => { backend: :gitlab, type: :group, object: 'gitlab.example.com:group' },
      'gitlab://gitlab.example.com/r/group/repo' => { backend: :gitlab, type: :repository, object: 'gitlab.example.com:group/repo' },
      'gitea://token@gitea.example.com/u/user' => { backend: :gitea, type: :user, object: 'gitea.example.com:user', data: { token: 'token' } },
      'gitea://user:token@gitea.example.com/u/user' => { backend: :gitea, type: :user, object: 'gitea.example.com:user', data: { token: 'token' } },
      'gitea://gitea.example.com/g/group' => { backend: :gitea, type: :group, object: 'gitea.example.com:group' },
      'gitea://gitea.example.com/r/group/repo' => { backend: :gitea, type: :repository, object: 'gitea.example.com:group/repo' },
      'gitea://user:token@gitea.example.com/r/group/repo?allow=tag&allow=release' => { backend: :gitea, type: :repository, object: 'gitea.example.com:group/repo', data: { token: 'token', allow: ['tag', 'release'] } },

      'git+https://git.example.com/full/path/to/repo' => { backend: :git, type: :repository, object: 'git+https://git.example.com/full/path/to/repo' },
      'git+ssh://git@git.example.com/full/path/to/repo' => { backend: :git, type: :repository, object: 'git+ssh://git@git.example.com/full/path/to/repo' },
      'git://git.example.com/full/path/to/repo' => { backend: :git, type: :repository, object: 'git://git.example.com/full/path/to/repo' },

      { uri: 'gitlab:token@u/user', data: { instance: 'git.example.com' } } => { backend: :gitlab, type: :user, object: 'user', data: { token: 'token', instance: 'git.example.com' } }
    }

    tests.each do |uri, result|
      data, err = @client.send(:parse_tracking_object, uri)

      assert_equal result, data
      assert_empty err
    end

    should_fail = %w[
      github:o/org
      https://gitlab.com/user/repo.git
      git+unix:///tmp/git.sock
    ]

    should_fail.each do |uri|
      _, err = @client.send(:parse_tracking_object, uri)

      assert err.any?
    end
  end

  def test_set_state
    data = {
      type: 'm.notice',
      tracking: []
    }

    @client.send :set_room_data, '!room:example.com', data
  end
end
