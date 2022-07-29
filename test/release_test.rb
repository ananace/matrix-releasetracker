# frozen_string_literal: true

require 'test_helper'

class ReleaseTest < Minitest::Test
  def setup
    data = {
      name: 'matrix-releasetracker',
      namespace: 'ananace',
      version: '1.0.0',
      commit_sha: '1234567890abcdefghijklmnopqrstuvwxyz',
      publish_date: Time.new(2049, 10, 3, 21, 0, 0),
      relese_notes: 'Lorem ipsum dolor sit amet',
      repo_url: 'http://example.com',
      release_url: 'http://example.com/release',
      avatar_url: 'https://upload.wikimedia.org/wikipedia/commons/b/b6/3_Bananas.jpg̈́',
      release_type: :release
    }
    @release = MatrixReleasetracker::Release.new(**data)
  end

  def test_creation
    rel = MatrixReleasetracker::Release.new

    assert rel

    assert_equal 'matrix-releasetracker', @release.name
    assert_equal 'ananace', @release.namespace
    assert_equal '1.0.0', @release.version

    rel = MatrixReleasetracker::Release.new(
      namespace: '',
      max_chars: 100_000
    )

    assert_nil rel.namespace
    assert_equal 40_000, rel.max_chars
  end

  def test_hash
    first = @release.stable_hash
    assert_equal first, @release.stable_hash

    @release.version = '1.0.1'

    second = @release.stable_hash
    assert second != first
    assert_equal second, @release.stable_hash

    @release.version = '1.0.0'

    assert_equal first, @release.stable_hash
  end

  def test_render
    assert_equal 'ananace / matrix-releasetracker 1.0.0', @release.to_s(:simple)
    assert_equal 'ananace / matrix-releasetracker released 1.0.0 on Sun, Oct  3 2049 (http://example.com/release)', @release.to_s(:plain)
    assert_equal <<~MD, @release.to_s(:markdown)
      #### [![avatar](https://upload.wikimedia.org/wikipedia/commons/b/b6/3_Bananas.jpg̈́) ananace / matrix-releasetracker](http://example.com)
      [1.0.0 released at Sun, Oct  3 2049](http://example.com/release)
    MD
    assert_equal <<~HTML.strip, @release.to_s(:html)
      <h4><a href=\"http://example.com\"><img src=\"https://upload.wikimedia.org/wikipedia/commons/b/b6/3_Bananas.jpg̈́\" alt=\"avatar\" height=\"32\" width=\"32\" /> ananace / matrix-releasetracker</a></h4>
      <p><a href=\"http://example.com/release\">1.0.0 released at Sun, Oct  3 2049</a></p>
      <br/>
    HTML
  end
end
