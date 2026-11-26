# frozen_string_literal: true

module Templates
  module PdfTextTags
    Error = Class.new(StandardError)

    TAG_REGEXP = /\{\{([^{}]+)\}\}/
    FIELD_TYPES = %w[text signature initials date checkbox].freeze
    LINE_Y_THRESHOLD = 0.01

    module_function

    def call(pdf_data)
      Pdfium::Document.open_bytes(pdf_data) do |doc|
        tags = extract_tags(doc)
        return [pdf_data, []] if tags.empty?

        redact_tags(doc, tags)

        io = StringIO.new
        io.binmode
        doc.save(io)

        [io.string, tags]
      end
    end

    def extract_tags(doc)
      doc.page_count.times.flat_map do |page_index|
        tags_on_page(doc.get_page(page_index), page_index)
      end
    end

    def tags_on_page(page, page_index)
      lines_for(page.text_nodes).flat_map { |line| tags_on_line(line, page_index) }
    end

    def lines_for(nodes)
      nodes.each_with_object([]) do |node, lines|
        line = lines.reverse_each.find { |group| (group.first.y - node.y).abs <= LINE_Y_THRESHOLD }

        if line
          line << node
        else
          lines << [node]
        end
      end
    end

    def tags_on_line(nodes, page_index)
      byte_to_node = []
      text = +''

      nodes.each_with_index do |node, index|
        text << node.content
        node.content.bytesize.times { byte_to_node << index }
      end

      tags = []

      text.scan(TAG_REGEXP) do
        match = Regexp.last_match
        start_index = byte_to_node[match.begin(0)]
        end_index = byte_to_node[match.end(0) - 1]
        next unless start_index && end_index

        tags << build_tag(match[1], nodes[start_index..end_index], page_index)
      end

      tags
    end

    def build_tag(raw, nodes, page_index)
      parse_tag(raw).merge(page: page_index, **bounding_box(nodes))
    end

    def parse_tag(raw)
      name = nil
      attributes = {}

      raw.split(';').each_with_index do |part, index|
        part = part.strip
        next if part.blank?

        if (separator = part.index('='))
          attributes[part[0...separator].strip.downcase] = part[(separator + 1)..].strip
        elsif index.zero?
          name = part
        end
      end

      type = attributes.fetch('type', 'text').downcase
      raise Error, "unsupported field type: #{type}" unless FIELD_TYPES.include?(type)

      {
        name: name.presence || type.capitalize,
        type:,
        role: attributes['role'].presence,
        required: attributes['required'].to_s.downcase != 'false'
      }
    end

    def bounding_box(nodes)
      x = nodes.map(&:x).min
      y = nodes.map(&:y).min
      width = nodes.map(&:endx).max - x
      height = nodes.map(&:endy).max - y
      x = x.clamp(0.0, 0.99)
      y = y.clamp(0.0, 0.99)

      {
        x: x.round(6),
        y: y.round(6),
        w: width.clamp(0.005, 1.0 - x).round(6),
        h: height.clamp(0.005, 1.0 - y).round(6)
      }
    end

    def redact_tags(doc, tags)
      tags.group_by { |tag| tag[:page] }.each do |page_index, page_tags|
        doc.get_page(page_index).redact(page_tags.map { |tag| redaction_rect(tag) })
      end
    end

    def redaction_rect(tag)
      { 'x' => tag[:x], 'y' => tag[:y], 'w' => tag[:w], 'h' => tag[:h], 'color' => 'white' }
    end
  end
end
