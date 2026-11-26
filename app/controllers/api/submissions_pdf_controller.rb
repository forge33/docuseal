# frozen_string_literal: true

module Api
  class SubmissionsPdfController < ApiBaseController
    def create
      authorize!(:create, Template)
      authorize!(:create, Submission)

      Params::SubmissionPdfValidator.call(params)

      params[:send_email] = false unless params.key?(:send_email)
      params[:send_sms] = false unless params.key?(:send_sms)

      submission = Submissions::CreateFromPdf.call(user: current_user, params:)

      WebhookUrls.enqueue_events(submission, 'submission.created')
      Submissions.send_signature_requests([submission])
      SearchEntries.enqueue_reindex([submission, submission.template])

      render json: serialize_submitters(submission)
    rescue Submissions::CreateFromPdf::Error, Templates::PdfTextTags::Error => e
      render json: { error: e.message }, status: :unprocessable_content
    rescue Pdfium::PdfiumError
      render json: { error: 'Invalid PDF' }, status: :unprocessable_content
    end

    private

    def serialize_submitters(submission)
      submission.submitters.map do |submitter|
        Submitters::SerializeForApi.call(submitter, with_documents: false, with_urls: true, params:)
      end
    end
  end
end
