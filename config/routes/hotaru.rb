# Copyright (C) 2026 Tsukaeru.
Zammad::Application.routes.draw do
  scope Rails.configuration.api_path do
    post '/tickets/:ticket_id/hotaru_reply_draft', to: 'hotaru_reply_drafts#create'
    post '/tickets/:ticket_id/hotaru_reply_draft/validate', to: 'hotaru_reply_drafts#validate'
  end
end
