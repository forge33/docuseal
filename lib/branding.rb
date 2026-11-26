# frozen_string_literal: true

module Branding
  class InvalidColor < StandardError; end
  class InvalidLogo < StandardError; end

  HEX_DIGITS = /\A(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})\z/
  LOGO_CONTENT_TYPES = %w[image/png image/jpeg image/gif image/webp].freeze
  MAX_LOGO_BYTES = 2.megabytes

  module_function

  def normalize_hex(value)
    hex = value.to_s.strip.delete_prefix('#')

    return unless hex.match?(HEX_DIGITS)

    hex = hex.chars.map { |char| char * 2 }.join if hex.length == 3

    "##{hex.downcase}"
  end

  def primary_color_for(account)
    return if account.blank?

    raw = account.account_configs.find_by(key: AccountConfig::FORM_PRIMARY_COLOR_KEY)&.value

    normalize_hex(raw)
  end

  def theme_css(hex)
    color = normalize_hex(hex)
    return if color.nil?

    hover = darken_hex(color)

    [
      theme_variables(color, hover),
      button_rule('.btn-neutral, [data-theme="docuseal"] .base-button', color),
      button_rule('.btn-neutral:hover, [data-theme="docuseal"] .base-button:hover', hover),
      %([data-theme="docuseal"] .link { color: #{color}; })
    ].join(' ')
  end

  def attach_logo(account, file)
    content_type = detect_logo_type(file)
    raise InvalidLogo if content_type.nil?

    file.tempfile.rewind
    account.logo.attach(io: file.tempfile, filename: file.original_filename, content_type:)
  end

  def detect_logo_type(file)
    return if file.blank? || !file.respond_to?(:tempfile) || !file.respond_to?(:size)
    return if file.size.to_i <= 0 || file.size.to_i > MAX_LOGO_BYTES
    return if FilenameUtils.dangerous_extension(file.original_filename.to_s)

    io = file.tempfile
    io.rewind
    type = Marcel::MimeType.for(io, name: file.original_filename.to_s, declared_type: file.content_type.to_s)

    type if LOGO_CONTENT_TYPES.include?(type)
  end

  def theme_variables(color, hover)
    base = hsl_string(color)
    focus = hsl_string(hover)

    '[data-theme="docuseal"] { ' \
      "--n: #{base}; --nf: #{focus}; --nc: 0 0% 100%; " \
      "--p: #{base}; --pf: #{focus}; --pc: 0 0% 100%; }"
  end

  def button_rule(selector, color)
    %([data-theme="docuseal"] #{selector} { background-color: #{color}; border-color: #{color}; })
  end

  def hsl_string(hex)
    red, green, blue = hex.delete_prefix('#').scan(/../).map { |channel| channel.to_i(16) / 255.0 }
    hue, saturation, lightness = rgb_to_hsl(red, green, blue)

    format('%<h>.0f %<s>.0f%% %<l>.0f%%', h: hue, s: saturation, l: lightness)
  end

  def rgb_to_hsl(red, green, blue)
    max = [red, green, blue].max
    min = [red, green, blue].min
    lightness = (max + min) / 2.0

    return [0, 0, lightness * 100] if max == min

    delta = max - min
    saturation = lightness > 0.5 ? delta / (2.0 - max - min) : delta / (max + min)

    [hue_from(red, green, blue, max, delta), saturation * 100, lightness * 100]
  end

  def hue_from(red, green, blue, max, delta)
    hue =
      if max == red
        ((green - blue) / delta) + (green < blue ? 6 : 0)
      elsif max == green
        ((blue - red) / delta) + 2
      else
        ((red - green) / delta) + 4
      end

    hue * 60
  end

  def darken_hex(hex, ratio = 0.88)
    channels = hex.delete_prefix('#').scan(/../).map do |channel|
      [(channel.to_i(16) * ratio).round, 0].max
    end

    "##{channels.map { |channel| format('%02x', channel) }.join}"
  end
end
