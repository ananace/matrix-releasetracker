module MatrixReleasetracker
  class Release
    attr_accessor :namespace, :name, :version, :version_name, :publish_date, :release_notes, :repo_url, :release_url, :avatar_url, :release_type

    def initialize
      @plain_template = File.join File.expand_path('templates', __dir__), 'plain.erb'
      @markdown_template = File.join File.expand_path('templates', __dir__), 'markdown.erb'
    end

    def full_name
      [namespace, name].compact.join ' / '
    end

    def render(template)
      erb = ERB.new template, 0, '-'
      erb.result(binding)
    end

    def to_s(format = :plain)
      version_name ||= version
      release_note_overflow = "   \n ..." if (release_notes || '').count("\n") > 10
      publish_date_str = publish_date.strftime('%a, %b %e %Y') if publish_date

      trimmed_release_notes = release_notes
      unless release_notes.nil? || release_notes.empty?
        if format == :plain
          trimmed_release_notes = release_notes.split("\n")[0, 2].map(&:rstrip).join "\n"
          trimmed_release_notes = release_notes_[0, 128] if release_notes_.length > 128
        else
          trimmed_release_notes = release_notes.split("\n")[0, 10].map(&:rstrip).join "\n"
          trimmed_release_notes = release_notes_[0, 512] if release_notes_.length > 512
        end
      end


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
  end
end

require 'kramdown'
module Kramdown
  class Converter::HtmlExtended < Converter::Html
    def convert_img(ele, indent)
      ele.attr['height'] = '32'
      ele.attr['width'] = '32'
      super(ele, indent)
    end
  end
end
