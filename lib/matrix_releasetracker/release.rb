# frozen_string_literal: true

module Digest
  autoload :SHA2, 'digest'
end

module MatrixReleasetracker
  class Release
    attr_accessor \
      :name, :version, :commit_sha, :publish_date, :release_notes, :repo_url,
      :release_url, :avatar_url, :release_type, :repositories_id, :release_id,
      :for_tracked, :max_lines
    attr_reader :namespace, :max_chars
    attr_writer :version_name

    def initialize(**args)
      @plain_template = File.join File.expand_path('templates', __dir__), 'plain.erb'
      @markdown_template = File.join File.expand_path('templates', __dir__), 'markdown.erb'

      @max_lines = 10
      @max_chars = 512
      @version_name = nil

      args.each do |k, v|
        send "#{k}=".to_sym, v if respond_to? "#{k}=".to_sym
      end
    end

    def namespace=(namespace)
      namespace = nil if namespace&.empty?
      @namespace = namespace
    end

    def max_chars=(max_chars)
      @max_chars = [max_chars, 40_000].min # Avoid overflowing Matrix message size
    end

    def version_name
      @version_name || version
    end

    def full_name
      [namespace, name].compact.join ' / '
    end

    def mxc_avatar_url; end

    def with_mxc_url
      dup.tap do |r|
        r.avatar_url = mxc_avatar_url
      end
    end

    def to_s(format = :simple)
      format = :markdown unless %i[simple plain markdown html].include? format
      case format
      when :simple
        "#{full_name} #{version_name || version}"
      when :plain
        render File.read(@plain_template)
      when :markdown
        render File.read(@markdown_template)
      when :html
        doc = Kramdown::Document.new(
          to_s(:markdown),
          auto_ids: false,
          remove_span_html_tags: true,
          syntax_highlighter: nil,
          math_engine: nil
        )
        "#{doc.to_html_extended}<br/>"
      end
    end

    def to_json(*params)
      {
        name: name,
        namespace: namespace,
        version: version,
        version_name: @version_name,
        commit_sha: commit_sha,
        publish_date: publish_date,
        release_notes: release_notes,
        repo_url: repo_url,
        release_url: release_url,
        avatar_url: avatar_url,
        release_type: release_type
      }.compact.to_json(*params)
    end

    def stable_hash
      Digest::SHA2.hexdigest to_json
    end

    private

    def render(template)
      erb = ERB.new template, trim_mode: '-'
      erb.result(binding)
    end

    def release_note_overflow
      return nil if max_lines.negative?

      "   \n ..." if (release_notes || '').count("\n") > max_lines
    end

    def publish_date_str
      publish_date&.strftime('%a, %b %e %Y')
    end

    def trimmed_release_notes
      return release_notes if max_lines.negative? && max_chars.negative?

      m_c = max_chars >= 0 ? max_chars : 40_000
      m_l = max_lines >= 0 ? max_lines : 1_000

      trimmed_release_notes = release_notes
      unless trimmed_release_notes.nil? || trimmed_release_notes.empty?
        trimmed_release_notes = trimmed_release_notes.split("\n")[0, m_l].map(&:rstrip).join "\n"
        trimmed_release_notes = trimmed_release_notes[0, m_c] if trimmed_release_notes.length > m_c
      end
      trimmed_release_notes
    end

    def abbrev_commit
      commit_sha[0, 7] unless commit_sha.nil? || commit_sha.empty?
    end
  end
end

require 'kramdown'

module Kramdown
  module Converter
    class HtmlExtended < Html
      def convert_img(ele, indent)
        if ele.attr['alt'] == 'avatar'
          ele.attr['height'] = '32'
          ele.attr['width'] = '32'
        end

        super(ele, indent)
      end
    end
  end
end
