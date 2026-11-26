# frozen_string_literal: true

RSpec.describe Templates::PdfTextTags do
  def pdf_with_text(*lines)
    document = HexaPDF::Document.new
    canvas = document.pages.add.canvas
    canvas.font('Helvetica', size: 14)

    lines.each_with_index do |line, index|
      canvas.text(line, at: [72, 720 - (index * 28)])
    end

    io = StringIO.new
    document.write(io, validate: false)
    io.string
  end

  def page_text(pdf_data)
    Pdfium::Document.open_bytes(pdf_data) do |doc|
      doc.page_count.times.map { |index| doc.get_page(index).text_nodes.map(&:content).join }.join("\n")
    end
  end

  it 'reads a text tag and removes it from the pdf' do
    pdf = pdf_with_text(
      'Agreement',
      '{{Signature;role=Signer;type=signature;required=false}}'
    )

    redacted, tags = described_class.call(pdf)

    expect(tags.size).to eq(1)
    expect(tags.first).to include(
      name: 'Signature',
      type: 'signature',
      role: 'Signer',
      required: false,
      page: 0
    )
    expect(tags.first[:w]).to be > 0
    expect(tags.first[:h]).to be > 0
    expect(page_text(redacted)).to include('Agreement')
    expect(page_text(redacted)).not_to include('{{')
    expect(page_text(redacted)).not_to include('Signature')
  end

  it 'rejects a field type outside the supported set' do
    pdf = pdf_with_text('{{Phone;type=phone}}')

    expect { described_class.call(pdf) }.to raise_error(described_class::Error, 'unsupported field type: phone')
  end

  it 'defaults a tag without a type to text' do
    pdf = pdf_with_text('{{Full name;role=Signer}}')

    _redacted, tags = described_class.call(pdf)

    expect(tags.first).to include(name: 'Full name', type: 'text', role: 'Signer', required: true)
  end
end
