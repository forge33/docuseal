# frozen_string_literal: true

module Params
  class SubmissionPdfValidator < BaseValidator
    def call
      required(params, :documents)
      required(params, :submitters)
      type(params, :documents, Array)
      type(params, :submitters, Array)
      type(params, :name, String)
      boolean(params, :send_email)

      in_path(params, :submitters) do |submitters|
        type(submitters, 0, Hash)
        unique_value(submitters, :role)
      end

      in_path_each(params, :submitters) do |submitter|
        required(submitter, :email)
        required(submitter, :role)
        type(submitter, :name, String)
        type(submitter, :email, String)
        type(submitter, :role, String)
        type(submitter, :external_id, String)
        email_format(submitter, :email, message: 'email is invalid')
      end

      in_path_each(params, :documents) do |document|
        required(document, :name)
        required(document, :file)
        type(document, :name, String)
        type(document, :file, String)
        type(document, :fields, Array)
        validate_fields(document)
      end
    end

    def validate_fields(document)
      in_path_each(document, :fields) do |field|
        required(field, :areas)
        type(field, :name, String)
        type(field, :role, String)
        type(field, :areas, Array)
        boolean(field, :required)
        value_in(field, :type, Templates::PdfTextTags::FIELD_TYPES) if field[:type].present?
        validate_areas(field)
      end
    end

    def validate_areas(field)
      in_path_each(field, :areas) do |area|
        required(area, :page)
        required(area, :x)
        required(area, :y)
        required(area, :w)
        required(area, :h)
      end
    end
  end
end
