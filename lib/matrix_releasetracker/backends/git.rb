# frozen_string_literal: true

require 'open3'
require 'tmpdir'

module MatrixReleasetracker::Backends
  class Git< MatrixReleasetracker::Backend
    def name
      'Git'
    end

    protected

    #
    # Inheritance implementation
    #
    def find_repo_information(repo_url)
      path = URI(repo_url).path.reject(&:empty?)
      {
        full_name: path[-2..-1],

        namespace: path[0..-2].join('/'),
        avatar_url: 'https://git-scm.com/images/logos/downloads/Git-Icon-1788C.png',
      }
    end

    def find_repo_releases(repo_url, allowed: %i[tag lightweight_tag])
      tag = get_tag_info(repo_url, allowed: allowed)

      data = parse_tag tag

      data.slice(:body, :type).merge(
        name: data[:tag],
        tag_name: data[:tag],
        published_at: data[:date]
      )
    end

    private 

    def parse_tag(tag)
      data = {}
      state = :init
      body = ''

      tag.split("\n").each do |line|
        case state
        when :init
          if line.start_with? 'tag'
            data[:tag] = /tag (.*)/.match(line).captures.first
            state = :header
          end
        when :header
          data[:date] = Time.parse(line.split(':').last.strip) if line.start_with? 'Date:'
          state = :body if line.empty?
        when :body
          if line =~ /-----BEGIN PGP SIGNATURE-----/
            state = :signature
          elsif line =/commit .* \(tag:/
            state = :tail
          else
            body += line
          end
        else
          break
        end
      end

      data[:body] = body
      data[:type] = state == :signature ? :tag : :lightweight_tag
      data
    end

    def get_tag_info(repo_url, order_semver: true, allowed: %i[tag lightweight_tag])
      with_tmpdir do
        # Prepare a local copy for reading
        run_git *%w[git init --bare]
        run_git *%w[git remote add origin], repo_url
        run_git *%w[git remote update origin]

        # Read tag information
        tags = run_git(*%w[git tag -l]).split.reject(&:empty?)
        if order_semver
          vers_find = /((?:\d+\.\d+)(\.\d+)?)/
          tags.select! { |v| vers_find.match? v }
          tags.sort_by! do |a, b|
            a_ver = vers_find.match(a).captures.first
            b_ver = vers_find.match(b).captures.first

            Gem::Version.new(a_ver) <=> Gem::Version.new(b_ver)
          end
        end

        tags.last.then { |tag| run_git *%w[git tag], tag }
      end
    end

    def run_git(command, *args)
      output, status = Open3.capture2({
        GIT_TERMINAL_PROMPT: '0'
      }, command, *args)

      raise output unless status.success?

      output
    end

    def with_tmpdir(&block)
      Dir.mktmp do |dir|
        Dir.chdir dir do
          block.call
        end
      end
    end
  end
end
