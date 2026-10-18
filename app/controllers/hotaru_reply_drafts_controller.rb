# Copyright (C) 2026 Tsukaeru.

class HotaruReplyDraftsController < ApplicationController
  prepend_before_action :require_agent_session!

  def create
    proxy_request
  end

  def validate
    proxy_request(validation: true)
  end

  private

  def require_agent_session!
    # API tokens and impersonation headers cannot assert an agent identity here.
    raise Exceptions::Forbidden, 'An agent browser session is required.' if session[:user_id].blank? || request_header_from.present?

    authentication_check
    authorize_current_actor!
  end

  def authorize_current_actor!
    Auth::RequestCache.clear
    User.uncached do
      @actor = User.find(session[:user_id])
      @ticket = Ticket.find(params[:ticket_id])
      enabled_groups = Array(Setting.get('hotaru_reply_draft_group_ids')).map(&:to_s)
      allowed = Setting.get('hotaru_reply_drafts') == true && enabled_groups.include?(@ticket.group_id.to_s)
      allowed &&= @actor.active && @actor.permissions?('ticket.agent')
      allowed &&= TicketPolicy.new(UserContext.new(@actor), @ticket).agent_update_access?
      raise Exceptions::Forbidden, 'Reply suggestions are unavailable for this ticket.' if !allowed
    end
  end

  def proxy_request(validation: false)
    response.headers['Cache-Control'] = 'no-store'
    request_id = params[:request_id].to_s
    language = params[:language].presence || 'auto'
    revision = params[:evidence_revision].to_s if validation
    if !Hotaru::ReplyDraftClient::UUID.match?(request_id) || !Hotaru::ReplyDraftClient::LANGUAGES.include?(language) || (validation && !Hotaru::ReplyDraftClient::REVISION.match?(revision))
      render json: { error: 'invalid_request' }, status: :unprocessable_entity
      return
    end
    if !validation && !Rails.cache.write("hotaru-reply-draft:#{@actor.id}", true, expires_in: 10.seconds, unless_exist: true)
      render json: { error: 'rate_limited' }, status: :too_many_requests
      return
    end
    result = Hotaru::ReplyDraftClient.new.call(actor_id: @actor.id, ticket_id: @ticket.id, request_id: request_id, language: language, evidence_revision: revision)
    # Read fresh records and policy after model latency, including group/role revocation.
    authorize_current_actor!
    render json: result
  rescue Hotaru::ReplyDraftClient::Unavailable
    render json: { error: 'suggestion_unavailable' }, status: :service_unavailable
  end
end
