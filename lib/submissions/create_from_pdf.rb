# frozen_string_literal: true

module Submissions
  module CreateFromPdf
    Error = Class.new(StandardError)

    MAX_FILE_SIZE = 50.megabytes

    module_function

    def call(user:, params:)
      submitters = Array.wrap(params[:submitters])
      documents = Array.wrap(params[:documents]).map { |document| prepare_document(document, submitters) }

      ApplicationRecord.transaction do
        template = build_template(user, params, submitters, documents)

        create_submission(template, user, params)
      end
    end

    def prepare_document(document, submitters)
      pdf = decode_pdf(document[:file])

      pdf, fields =
        if document[:fields].present?
          [pdf, explicit_fields(document[:fields], submitters, pdf)]
        else
          tagged_fields(pdf, submitters)
        end

      { name: document[:name].to_s, pdf:, fields: }
    end

    def tagged_fields(pdf, submitters)
      pdf, tags = Templates::PdfTextTags.call(pdf)
      raise Error, 'document does not contain fields' if tags.empty?

      fields = tags.map { |tag| tag.merge(role: match_role(tag[:role], submitters)) }

      [pdf, fields]
    end

    def explicit_fields(fields, submitters, pdf)
      page_count = page_count_for(pdf)

      fields.flat_map do |field|
        type = field[:type].to_s.downcase.presence || 'text'
        raise Error, "unsupported field type: #{type}" unless Templates::PdfTextTags::FIELD_TYPES.include?(type)

        Array.wrap(field[:areas]).map do |area|
          {
            name: field[:name].presence || type.capitalize,
            type:,
            role: match_role(field[:role], submitters),
            required: required_field?(field),
            **area_box(area, page_count)
          }
        end
      end
    end

    def build_template(user, params, submitters, documents)
      template = user.account.templates.create!(
        author: user,
        name: params[:name].presence || documents.first[:name],
        source: 'api',
        submitters: submitter_definitions(submitters)
      )

      documents.each { |document| attach_document(template, document) }

      template.save!
      template
    end

    def attach_document(template, document)
      attachment = store_pdf(template, document[:name], document[:pdf])

      template.schema = [
        *template.schema,
        { 'attachment_uuid' => attachment.uuid, 'name' => document[:name] }
      ]
      template.fields = [*template.fields, *field_definitions(template, attachment, document[:fields])]
    end

    def store_pdf(template, name, pdf_data)
      filename = name.to_s.downcase.end_with?('.pdf') ? name : "#{name}.pdf"
      tempfile = Tempfile.new(['submission', '.pdf'])
      tempfile.binmode
      tempfile.write(pdf_data)
      tempfile.rewind

      file = ActionDispatch::Http::UploadedFile.new(tempfile:, filename:, type: 'application/pdf')
      attachment = Templates::CreateAttachments.create_document(template, file, pdf_data, {})

      Pdfium::Document.open_bytes(pdf_data) do |doc|
        Templates::ProcessDocument.call(attachment, pdf_data, doc:)
      end

      attachment
    ensure
      tempfile&.close!
    end

    def field_definitions(template, attachment, fields)
      fields.group_by { |field| [field[:role], field[:name], field[:type]] }.values.map do |group|
        sample = group.first
        submitter = template.submitters.find { |item| item['name'] == sample[:role] }

        {
          'uuid' => SecureRandom.uuid,
          'submitter_uuid' => submitter['uuid'],
          'name' => sample[:name],
          'type' => sample[:type],
          'required' => sample[:required],
          'preferences' => {},
          'areas' => group.map { |field| area_attributes(field, attachment.uuid) }
        }
      end
    end

    def create_submission(template, user, params)
      submissions_attrs, attachments =
        Submissions::NormalizeParamUtils.normalize_submissions_params!(submission_attrs(params), template,
                                                                        purpose: :api)

      submissions = Submissions.create_from_submitters(
        template:,
        user:,
        source: :api,
        submitters_order: 'preserved',
        submissions_attrs:,
        params:
      )

      submitters = submissions.flat_map(&:submitters)
      Submissions::NormalizeParamUtils.save_default_value_attachments!(attachments, submitters)

      submissions.first || raise(Error, 'submitters are invalid')
    end

    def submission_attrs(params)
      {
        name: params[:name],
        submitters: Array.wrap(params[:submitters]).map do |submitter|
          {
            name: submitter[:name],
            email: submitter[:email],
            role: submitter[:role],
            external_id: submitter[:external_id]
          }
        end
      }
    end

    def submitter_definitions(submitters)
      submitters.map do |submitter|
        { 'name' => submitter[:role].to_s, 'uuid' => SecureRandom.uuid }
      end
    end

    def match_role(role, submitters)
      names = submitters.map { |submitter| submitter[:role].to_s }

      if role.blank?
        raise Error, 'field role is required when a document has more than one submitter' if names.size > 1

        return names.first
      end

      names.find { |name| name.casecmp?(role.to_s) } ||
        raise(Error, "role #{role} does not match a submitter")
    end

    def required_field?(field)
      return true unless field.key?(:required)

      ActiveModel::Type::Boolean.new.cast(field[:required]) != false
    end

    def area_box(area, page_count)
      page = Integer(area[:page])
      raise Error, 'page starts at 1' if page < 1
      raise Error, 'page is out of range' if page > page_count

      x, y, width, height = %i[x y w h].map { |key| Float(area[key]) }
      unless [x, y, width, height].all? { |number| number.finite? && number >= 0 && number <= 1 }
        raise Error, 'area coordinates must be between 0 and 1'
      end
      raise Error, 'area width and height must be greater than 0' unless width.positive? && height.positive?

      { page: page - 1, x:, y:, w: width, h: height }
    rescue ArgumentError
      raise Error, 'area coordinates must be numbers'
    end

    def area_attributes(field, uuid)
      {
        'x' => field[:x].to_f,
        'y' => field[:y].to_f,
        'w' => field[:w].to_f,
        'h' => field[:h].to_f,
        'page' => field[:page],
        'attachment_uuid' => uuid
      }
    end

    def page_count_for(pdf_data)
      Pdfium::Document.open_bytes(pdf_data, &:page_count)
    end

    def decode_pdf(file)
      payload = file.to_s.sub(/\Adata:.*?;base64,/i, '').gsub(/\s/, '')
      data = Base64.strict_decode64(payload)

      raise Error, 'file must be a base64-encoded PDF' unless data.start_with?('%PDF')
      raise Error, 'PDF file is too large' if data.bytesize > MAX_FILE_SIZE

      data
    rescue ArgumentError
      raise Error, 'file must be a base64-encoded PDF'
    end
  end
end
