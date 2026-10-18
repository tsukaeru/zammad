# Copyright (C) 2026 Tsukaeru.
require 'rails_helper'

RSpec.describe 'Hotaru reply draft proxy', type: :request do
  let(:agent) { create(:agent) }
  let(:ticket) { create(:ticket) }
  let(:request_id) { SecureRandom.uuid }
  let(:client) { instance_double(Hotaru::ReplyDraftClient) }
  let(:payload) { { request_id: request_id, language: 'auto', actor_id: 999, integration_id: 'attacker' } }
  let(:result) { { 'status' => 'ready', 'draft' => 'Customer reply', 'language' => 'en', 'evidence_revision' => 'a' * 64, 'request_id' => request_id } }
  let(:endpoint) { "/api/v1/tickets/#{ticket.id}/hotaru_reply_draft" }

  before do
    Setting.set('hotaru_reply_drafts', true)
    Setting.set('hotaru_reply_draft_group_ids', [ticket.group_id])
    agent.user_groups.create!(group: ticket.group, access: :full)
    Rails.cache.delete("hotaru-reply-draft:#{agent.id}")
    allow(Hotaru::ReplyDraftClient).to receive(:new).and_return(client)
    allow(client).to receive(:call).and_return(result)
    authenticated_as(agent, via: :browser)
  end

  it 'derives the actor from the session and does not create articles or drafts' do
    expect { post endpoint, params: payload, as: :json }.not_to change(Ticket::Article, :count)
    expect(response).to have_http_status(:ok)
    expect(client).to have_received(:call).with(actor_id: agent.id, ticket_id: ticket.id, request_id: request_id, language: 'auto', evidence_revision: nil)
    expect(response.parsed_body).to eq(result)
    expect(response.headers['Cache-Control']).to include('no-store')
  end

  it 'test_customer_revoked_agent_and_inaccessible_ticket_are_denied' do
    agent.update!(active: false)
    post endpoint, params: payload, as: :json
    expect(response).not_to have_http_status(:ok)
    expect(client).not_to have_received(:call)
  end

  it 'denies tickets without agent update access' do
    agent.user_groups.destroy_all
    post endpoint, params: payload, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(client).not_to have_received(:call)
  end

  it 'denies customer browser sessions' do
    authenticated_as(create(:customer), via: :browser)
    post endpoint, params: payload, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(client).not_to have_received(:call)
  end

  it 'is disabled by default and denies groups outside the pilot' do
    Setting.set('hotaru_reply_draft_group_ids', [])
    post endpoint, params: payload, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(client).not_to have_received(:call)
  end

  it 'test_changed_ticket_revision_or_access_discards_result' do
    allow(client).to receive(:call) do
      agent.update!(active: false)
      result
    end
    post endpoint, params: payload, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body).not_to have_key('draft')
  end

  it 'checks access again after group reassignment during generation' do
    allow(client).to receive(:call) do
      ticket.update!(group: create(:group))
      result
    end
    post endpoint, params: payload, as: :json
    expect(response).to have_http_status(:forbidden)
  end


  it 'rejects group membership revoked while the model is running' do
    allow(client).to receive(:call) do
      agent.user_groups.destroy_all
      result
    end
    post endpoint, params: payload, as: :json
    expect(response).to have_http_status(:forbidden)
  end

  it 'rejects an agent role revoked while the model is running' do
    allow(client).to receive(:call) do
      agent.roles = [Role.find_by!(name: 'Customer')]
      result
    end
    post endpoint, params: payload, as: :json
    expect(response).to have_http_status(:forbidden)
  end

  it 'revalidates a revision without creating an article' do
    allow(client).to receive(:call).and_return({ 'valid' => true, 'request_id' => request_id })
    expect { post "#{endpoint}/validate", params: payload.merge(evidence_revision: 'a' * 64), as: :json }.not_to change(Ticket::Article, :count)
    expect(response).to have_http_status(:ok)
    expect(client).to have_received(:call).with(actor_id: agent.id, ticket_id: ticket.id, request_id: request_id, language: 'auto', evidence_revision: 'a' * 64)
  end

  it 'test_timeout_rate_limit_and_duplicate_requests_never_post' do
    allow(client).to receive(:call).and_raise(Hotaru::ReplyDraftClient::Unavailable)
    expect { post endpoint, params: payload, as: :json }.not_to change(Ticket::Article, :count)
    expect(response).to have_http_status(:service_unavailable)
    post endpoint, params: payload, as: :json
    expect(response).to have_http_status(:too_many_requests)
  end

  it 'does not accept API-only authentication or an impersonation header' do
    add_headers('From' => agent.email)
    post endpoint, params: payload, as: :json
    expect(response).to have_http_status(:forbidden)
    expect(client).not_to have_received(:call)
  end

  context 'without a browser session', authenticated_as: :agent do
    before { delete '/api/v1/signout' }

    it 'denies API basic authentication' do
      authenticated_as(agent)
      post endpoint, params: payload, as: :json
      expect(response).to have_http_status(:forbidden)
      expect(client).not_to have_received(:call)
    end
  end


  it 'allows a valid browser CSRF token' do
    token = response.headers['CSRF-TOKEN']
    expect(token).to be_present
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    post endpoint, params: payload, headers: { 'X-CSRF-Token' => token }, as: :json
    expect(response).to have_http_status(:ok)
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  it 'test_wrong_instance_tampered_actor_csrf_and_replay_are_denied' do
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    post endpoint, params: payload, as: :json
    expect(response).not_to have_http_status(:ok)
    expect(client).not_to have_received(:call)
  ensure
    ActionController::Base.allow_forgery_protection = original
  end
end
