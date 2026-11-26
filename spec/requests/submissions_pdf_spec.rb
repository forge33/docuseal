# frozen_string_literal: true

describe 'Submission PDF API' do
  let(:author) { create(:user) }

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

  def post_pdf(payload)
    post '/api/submissions/pdf',
         headers: { 'x-auth-token': author.access_token.token },
         params: payload.to_json
  end

  it 'creates a submission from text tags' do
    pdf = pdf_with_text(
      'Agreement',
      '{{Signature;role=Signer;type=signature}}',
      '{{Initials;role=Witness;type=initials}}'
    )

    expect do
      post_pdf(
        name: 'Agreement',
        documents: [{ name: 'agreement.pdf', file: Base64.strict_encode64(pdf) }],
        submitters: [
          { name: 'Ada', email: 'ada@example.com', role: 'Signer', external_id: 'signer-1' },
          { name: 'Grace', email: 'grace@example.com', role: 'Witness', external_id: 'witness-1' }
        ]
      )
    end.not_to change(SendSubmitterInvitationEmailJob.jobs, :size)

    expect(response).to have_http_status(:ok)

    submission = Submission.last
    body = response.parsed_body
    signer = submission.submitters.find { |submitter| submitter.email == 'ada@example.com' }

    expect(body.pluck('email')).to eq(['ada@example.com', 'grace@example.com'])
    expect(body.pluck('role')).to eq(%w[Signer Witness])
    expect(body.first).to include(
      'id' => signer.id,
      'submission_id' => submission.id,
      'slug' => signer.slug,
      'external_id' => 'signer-1',
      'embed_src' => "#{Docuseal::DEFAULT_APP_URL}/s/#{signer.slug}",
      'preferences' => { 'send_email' => false, 'send_sms' => false }
    )

    roles = submission.template.submitters.to_h { |submitter| [submitter['uuid'], submitter['name']] }
    expect(submission.template.fields.map { |field| [field['name'], field['type'], roles[field['submitter_uuid']]] })
      .to contain_exactly(['Signature', 'signature', 'Signer'], ['Initials', 'initials', 'Witness'])

    stored = submission.template.documents.first.download
    text = Pdfium::Document.open_bytes(stored) do |doc|
      doc.get_page(0).text_nodes.map(&:content).join
    end
    expect(text).to include('Agreement')
    expect(text).not_to include('{{')
  end

  it 'creates fields from explicit areas when the pdf has no tags' do
    pdf = pdf_with_text('Agreement')

    post_pdf(
      documents: [{
        name: 'agreement.pdf',
        file: Base64.strict_encode64(pdf),
        fields: [{
          name: 'Signature',
          type: 'signature',
          role: 'Signer',
          areas: [{ page: 1, x: 0.1, y: 0.2, w: 0.3, h: 0.05 }]
        }]
      }],
      submitters: [{ name: 'Ada', email: 'ada@example.com', role: 'Signer' }]
    )

    expect(response).to have_http_status(:ok)

    field = Submission.last.template.fields.first
    expect(field['areas'].first).to include(
      'page' => 0,
      'x' => 0.1,
      'y' => 0.2,
      'w' => 0.3,
      'h' => 0.05
    )
  end

  it 'rejects a tag role that does not match a submitter' do
    pdf = pdf_with_text('{{Signature;role=Signer;type=signature}}')

    expect do
      post_pdf(
        documents: [{ name: 'agreement.pdf', file: Base64.strict_encode64(pdf) }],
        submitters: [{ name: 'Ada', email: 'ada@example.com', role: 'Witness' }]
      )
    end.not_to change(Submission, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to eq({ 'error' => 'role Signer does not match a submitter' })
  end

  it 'enqueues submission.created' do
    create(:webhook_url, account: author.account, events: ['submission.created'])
    pdf = pdf_with_text('{{Date;role=Signer;type=date}}')

    post_pdf(
      documents: [{ name: 'agreement.pdf', file: Base64.strict_encode64(pdf) }],
      submitters: [{ email: 'ada@example.com', role: 'Signer' }]
    )

    expect(response).to have_http_status(:ok)
    expect(SendSubmissionCreatedWebhookRequestJob.jobs.size).to eq(1)
  end
end
