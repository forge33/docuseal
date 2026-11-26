# frozen_string_literal: true

describe 'Self-hosted public URL' do
  let(:account) { create(:account, name: 'Northwind') }
  let(:user) { create(:user, account:) }
  let(:submitter) do
    uuid = SecureRandom.uuid
    template = Template.create!(
      account:,
      author: user,
      name: 'Agreement',
      submitters: [{ 'name' => 'Signer', 'uuid' => uuid }]
    )
    submission = Submission.create!(
      template:,
      account:,
      created_by_user: user,
      name: 'Agreement',
      template_fields: [],
      template_schema: [],
      template_submitters: template.submitters
    )
    Submitter.create!(submission:, account:, uuid:, email: 'signer@example.com', name: 'Ada')
  end

  around do |example|
    previous = ENV.fetch('APP_URL', :missing)
    ENV.delete('APP_URL')
    Docuseal.refresh_default_url_options!
    example.run
  ensure
    if previous == :missing
      ENV.delete('APP_URL')
    else
      ENV['APP_URL'] = previous
    end

    Docuseal.refresh_default_url_options!
  end

  before do
    allow(Docuseal).to receive(:multitenant?).and_return(false)
    create(:encrypted_config, account:, key: EncryptedConfig::APP_URL_KEY, value: 'https://sign.example.com')
    Docuseal.refresh_default_url_options!
    stub_const('ReplaceEmailVariables::EMAIL_HOST', 'mail.example.test')
  end

  it 'uses the configured app URL for embed_src and email links when multitenant is off' do
    expect(Docuseal.multitenant?).to be(false)

    payload = Submitters::SerializeForApi.call(submitter, with_documents: false, with_urls: true)

    expect(payload['embed_src']).to eq("https://sign.example.com/s/#{submitter.slug}")

    link = ReplaceEmailVariables.call('{submitter.link}', submitter:)

    expect(link).to start_with("https://sign.example.com/s/#{submitter.slug}")
    expect(link).not_to include('mail.example.test')

    mail = SubmitterMailer.invitation_email(submitter)

    expect(mail.body.encoded).to include("https://sign.example.com/s/#{submitter.slug}")
    expect(mail.body.encoded).not_to include('mail.example.test')
  end
end
