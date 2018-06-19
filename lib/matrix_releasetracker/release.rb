module MatrixReleasetracker
  class Release
    attr_accessor :namespace, :name, :version, :version_name, :publish_date, :release_notes, :repo_url, :release_url, :avatar_url

    def full_name
      [namespace, name].compact.join ' / '
    end

    def to_s(format = :plain)
      format = :markdown unless %i[plain markdown html].include? format
      formatstr = case format
                  when :plain
                    "%{full_name} published %{version} on %{publish_date} (%{release_url})#{"\n%{release_notes}" unless release_notes.nil? || release_notes.empty?}"
                  when :markdown
                    "#### [#{"![avatar](#{avatar_url}) " unless avatar_url.nil? || avatar_url.empty?}%{full_name}](%{repo_url}) [%{version}](%{release_url})\n[%{version_name} published %{publish_date}](%{release_url})#{"\n\n---\n%{release_notes}%{release_note_overflow}" unless release_notes.nil? || release_notes.empty?}"
                  when :html
                    return Kramdown::Document.new(to_s(:markdown)).to_html_extended + '<br/>'
                  end

      unless release_notes.nil? || release_notes.empty?
        if format == :plain
          release_notes_ = release_notes.split("\n")[0, 2].map(&:rstrip).join "\n"
          release_notes_ = _release_notes[0, 128] if _release_notes.length > 128
        else
          release_notes_ = release_notes.split("\n")[0, 10].map(&:rstrip).join "\n"
          release_notes_ = _release_notes[0, 512] if _release_notes.length > 512
        end
      end

      format(formatstr,
             namespace: namespace,
             name: name,
             full_name: full_name,
             version: version,
             version_name: (version_name.nil? || version_name.empty? ? version : version_name),
             publish_date: (publish_date ? publish_date.strftime('%a, %b %e %Y') : nil),
             release_notes: release_notes_,
             release_note_overflow: ("   \n ..." if (release_notes || '').count("\n") > 10),
             repo_url: repo_url,
             release_url: release_url,
             avatar_url: avatar_url)
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
