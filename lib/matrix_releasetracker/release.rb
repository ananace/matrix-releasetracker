module Digest
  autoload :SHA2, 'digest'
end

module MatrixReleasetracker
  class Release
    attr_accessor :namespace, :name, :version, :commit_sha, :publish_date, :release_notes, :repo_url, :release_url, :avatar_url, :release_type
    attr_accessor :repositories_id, :release_id
    attr_accessor :max_lines, :max_chars
    attr_writer :version_name

    def initialize
      @plain_template = File.join File.expand_path('templates', __dir__), 'plain.erb'
      @markdown_template = File.join File.expand_path('templates', __dir__), 'markdown.erb'

      @max_lines = 10
      @max_chars = 512
    end

    def to_s
      "#{full_name} #{version_name || version}"
    end

    def version_name
      @version_name || name
    end

    def full_name
      [namespace, name].compact.join ' / '
    end

    def mxc_avatar_url
      
    end

    def with_mxc_url
      return dup.tap do |r|
        r.avatar_url = mxc_avatar_url
      end
    end

    def to_s(format = :plain)
      format = :markdown unless %i[plain markdown html].include? format
      result = case format
                  when :plain
                    render File.read(@plain_template)
                  when :markdown
                    render File.read(@markdown_template)
                  when :html
                    return Kramdown::Document.new(to_s(:markdown)).to_html_extended + '<br/>'
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
      erb = ERB.new template, 0, '-'
      erb.result(binding)
    end

    def release_note_overflow
      "   \n ..." if (release_notes || '').count("\n") > 10
    end

    def publish_date_str
      publish_date.strftime('%a, %b %e %Y') if publish_date
    end

    def trimmed_release_notes
      trimmed_release_notes = release_notes
      unless trimmed_release_notes.nil? || trimmed_release_notes.empty?
        trimmed_release_notes = trimmed_release_notes.split("\n")[0, max_lines].map(&:rstrip).join "\n"
        trimmed_release_notes = trimmed_release_notes[0, max_chars] if trimmed_release_notes.length > max_chars
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
  class Converter::HtmlExtended < Converter::Html
    def convert_img(ele, indent)
      if ele.attr['alt'] == 'avatar'
        ele.attr['height'] = '32'
        ele.attr['width'] = '32'
      end

      super(ele, indent)
    end
  end
end
