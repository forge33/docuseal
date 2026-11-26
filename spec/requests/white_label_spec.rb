# frozen_string_literal: true

describe 'Self-hosted white label' do
  let(:account) { create(:account, name: 'Northwind') }
  let(:user) { create(:user, account:) }

  def png_upload
    FileUtils.mkdir_p(Rails.root.join('tmp'))
    path = Rails.root.join('tmp/white-label-logo.png').to_s
    png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='
    File.binwrite(path, Base64.decode64(png))
    Rack::Test::UploadedFile.new(path, 'image/png')
  end

  def text_upload
    FileUtils.mkdir_p(Rails.root.join('tmp'))
    path = Rails.root.join('tmp/white-label-logo.txt').to_s
    File.write(path, 'not an image')
    Rack::Test::UploadedFile.new(path, 'text/plain')
  end

  def signer
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

  before do
    allow(Docuseal).to receive(:multitenant?).and_return(false)
    sign_in(user)
  end

  describe 'logo' do
    it 'saves a logo, shows it on the signing form, and clears it' do
      patch settings_personalization_path, params: { logo: png_upload }

      expect(response).to redirect_to(settings_personalization_path)
      expect(account.reload.logo).to be_attached
      expect(account.logo.filename.to_s).to eq('white-label-logo.png')

      get submit_form_path(signer.slug)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('alt="Northwind"')
      expect(response.body).to include('white-label-logo.png')
      expect(response.body).to include('Powered by')
      expect(response.body).to include('data-attribution="true"')

      delete settings_personalization_path

      expect(response).to redirect_to(settings_personalization_path)
      expect(account.reload.logo).not_to be_attached

      get submit_form_path(signer.slug)

      expect(response.body).not_to include('alt="Northwind"')
      expect(response.body).to include('Powered by')
    end

    it 'rejects a file that is not an image' do
      patch settings_personalization_path, params: { logo: text_upload }

      expect(response).to redirect_to(settings_personalization_path)
      expect(flash[:alert]).to eq(I18n.t('invalid_file_type'))
      expect(account.reload.logo).not_to be_attached
    end
  end

  describe 'primary colour' do
    it 'rejects an invalid colour and applies a hex colour on the signing form' do
      post settings_personalization_path, params: {
        account_config: { key: AccountConfig::FORM_PRIMARY_COLOR_KEY, value: 'red' }
      }

      expect(response).to redirect_to(settings_personalization_path)
      expect(flash[:alert]).to eq(I18n.t('invalid_color'))
      expect(account.account_configs.find_by(key: AccountConfig::FORM_PRIMARY_COLOR_KEY)).to be_nil

      post settings_personalization_path, params: {
        account_config: { key: AccountConfig::FORM_PRIMARY_COLOR_KEY, value: '#abc' }
      }

      config = account.account_configs.find_by!(key: AccountConfig::FORM_PRIMARY_COLOR_KEY)
      expect(config.value).to eq('#aabbcc')

      get submit_form_path(signer.slug)

      expect(response.body).to include('id="brand-color"')
      expect(response.body).to include('background-color: #aabbcc')
      expect(response.body).to include('Powered by')
      expect(response.body).to include('data-attribution="true"')

      post settings_personalization_path, params: {
        account_config: { key: AccountConfig::FORM_PRIMARY_COLOR_KEY, value: '' }
      }

      expect(account.account_configs.find_by(key: AccountConfig::FORM_PRIMARY_COLOR_KEY)).to be_nil
    end
  end

  describe 'app URL' do
    it 'rejects an invalid public URL' do
      patch settings_account_path, params: {
        account: { name: account.name, timezone: account.timezone, locale: account.locale },
        encrypted_config: { value: 'not a url' }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(EncryptedConfig.find_by(account:, key: EncryptedConfig::APP_URL_KEY)).to be_nil
    end
  end
end
