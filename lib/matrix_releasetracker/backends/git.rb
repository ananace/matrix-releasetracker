# frozen_string_literal: true

require 'open3'
require 'time'
require 'tmpdir'

module MatrixReleasetracker::Backends
  class Git < MatrixReleasetracker::Backend
    class GitError < MatrixReleasetracker::Error; end
    class ParseError < MatrixReleasetracker::Error; end

    def name
      'Git'
    end

    def valid?(repo_url)
      uri = URI(repo_url)
      return false unless u.scheme =~ /^git(\+(https?|ssh))?$/

      uri.scheme = uri.scheme.sub('git+', '')

      run_git *%w[git ls-remote --tags], uri.to_s
      true
    rescue GitError
      false
    end

    protected

    #
    # Inheritance implementation
    #
    def find_repo_information(repo_url, avatar: nil, **params)
      path = URI(repo_url).path.split('/').reject(&:empty?)
      {
        full_name: path[-2..-1].join('/'),

        namespace: path[0..-2].join('/'),
        avatar_url: avatar || 'https://git-scm.com/images/logos/downloads/Git-Icon-1788C.png',
      }
    end

    def find_repo_releases(repo_url, limit: 1, strict_semver: false, allowed: %i[tag lightweight_tag], **params)
      uri = URI(repo_url)
      uri.scheme = uri.scheme.sub('git+', '')

      tags = get_tag_info(uri.to_s, limit: limit, strict_semver: order_semver, allowed: allowed.map { |s| s.to_s.to_sym })
      tags.map do |data|
        data.slice(:body, :type).merge(
          name: data[:tag],
          tag_name: data[:tag],
          published_at: data[:date]
        )
      end
    end

    private 

    def parse_tag(tag)
      data = {
        tag: tag[:tag]
      }
      state = :init
      body = []

      tag[:text].split("\n").each do |line|
        case state
        when :init
          tag = /^tag (.+)/
          lightweight = /^commit (\w+)/

          if tag.match?(line)
            data[:tag] = tag.match(line).captures.first
            state = :header
          elsif lightweight.match?(line)
            state = :header
          end
        when :header
          data[:date] = Time.parse(line.split(':')[1..-1].join(':').strip) if line.start_with? 'Date:'
          state = :body if line.empty?
        when :body
          if line =~ /^-+BEGIN PGP SIGNATURE/
            state = :signature
          elsif line =~ /^commit .* \(tag:/ || line =~ /^diff --/ || line =~ /^index .*\.\..*/
            state = :tail
          else
            body << line
          end
        else
          break
        end
      end

      raise ParseError, 'Unexpected EoF on parsing tag data' unless %i[signature tail].include? state

      data[:body] = body.join("\n")
      data[:type] = state == :signature ? :tag : :lightweight_tag
      data
    end

    def get_tag_info(repo_url, limit: 1, strict_semver: false, allowed: %i[tag lightweight_tag])
      with_tmpdir do
        # Prepare a local copy for reading
        run_git *%w[git init --bare]
        run_git *%w[git remote add origin], repo_url
        run_git *%w[git remote update origin]

        # Read tag information
        tags = run_git(*%w[git tag -l]).split.reject(&:empty?)
        if strict_semver
          vers_find = /((?:\d+\.\d+)(\.\d+)?)/
          tags.select! { |v| vers_find.match? v }
          tags.sort_by! do |a, b|
            next 1 if a.nil?
            next -1 if b.nil?

            a_ver = vers_find.match(a).captures.first
            b_ver = vers_find.match(b).captures.first

            Gem::Version.new(a_ver) <=> Gem::Version.new(b_ver)
          end
        end

        ret = []
        tags.reverse.each do |tag|
          data = parse_tag(
            tag: tag,
            text: run_git(*%w[git show], tag)
          )

          ret << data if allowed.include? data[:type]
          return ret if ret.count >= limit
        end
        ret
      end
    end

    def run_git(command, *args)
      # logger.debug "$ #{command} #{args.join " "}"
      output, error, status = Open3.capture3({
        'GIT_TERMINAL_PROMPT' => '0'
      }, command, *args)

      raise GitError, error unless status.success?

      output
    end

    def with_tmpdir(&block)
      Dir.mktmpdir do |dir|
        Dir.chdir dir do
          block.call
        end
      end
    end
  end
end
