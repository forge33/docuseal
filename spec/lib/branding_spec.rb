# frozen_string_literal: true

describe Branding do
  describe '.normalize_hex' do
    it 'accepts 3 and 6 digit hex colours' do
      expect(described_class.normalize_hex('#abc')).to eq('#aabbcc')
      expect(described_class.normalize_hex('112233')).to eq('#112233')
      expect(described_class.normalize_hex('#112233')).to eq('#112233')
    end

    it 'rejects anything that is not a hex colour' do
      expect(described_class.normalize_hex('red')).to be_nil
      expect(described_class.normalize_hex('#1122')).to be_nil
      expect(described_class.normalize_hex('#11223344')).to be_nil
      expect(described_class.normalize_hex(nil)).to be_nil
    end
  end

  describe '.theme_css' do
    it 'emits the colour for signing-form buttons and leaves unset colours alone' do
      css = described_class.theme_css('#112233')

      expect(css).to include('background-color: #112233')
      expect(css).to include('--n:')
      expect(css).to include('.btn-neutral')
      expect(css).to include('.base-button')
      expect(described_class.theme_css(nil)).to be_nil
      expect(described_class.theme_css('nope')).to be_nil
    end
  end
end
