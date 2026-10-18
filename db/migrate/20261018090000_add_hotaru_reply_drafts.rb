# Copyright (C) 2026 Tsukaeru.
class AddHotaruReplyDrafts < ActiveRecord::Migration[8.0]
  def up
    return if !Setting.exists?(name: 'system_init_done')

    Setting.create_if_not_exists(
      title: 'Hotaru reply suggestions', name: 'hotaru_reply_drafts',
      area: 'Integration::Hotaru', state: false, frontend: true,
      description: 'Enable customer reply suggestions in the classic agent composer.',
    )
    Setting.create_if_not_exists(
      title: 'Hotaru reply suggestion groups', name: 'hotaru_reply_draft_group_ids',
      area: 'Integration::Hotaru', state: [], frontend: true,
      description: 'Group IDs allowed to request customer reply suggestions.',
    )
  end

  def down
    Setting.where(name: %w[hotaru_reply_drafts hotaru_reply_draft_group_ids]).destroy_all
  end
end
