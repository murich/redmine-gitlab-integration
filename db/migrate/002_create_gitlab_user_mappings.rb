class CreateGitlabUserMappings < ActiveRecord::Migration[7.2]
  def change
    create_table :gitlab_user_mappings do |t|
      t.integer :redmine_user_id, null: false
      t.integer :gitlab_user_id, null: false
      t.string :gitlab_username, limit: 255
      t.string :match_method, limit: 50  # 'casdoor_id', 'username', 'email'
      t.datetime :last_synced_at         # Track last synchronization
      t.timestamps
    end

    # Ensure unique Redmine user (one-to-one mapping)
    add_index :gitlab_user_mappings, :redmine_user_id, unique: true, name: 'index_gitlab_user_mappings_on_redmine_user_id'

    # Allow lookup by GitLab user ID
    add_index :gitlab_user_mappings, :gitlab_user_id, name: 'index_gitlab_user_mappings_on_gitlab_user_id'

    # Allow lookup by GitLab username
    add_index :gitlab_user_mappings, :gitlab_username, name: 'index_gitlab_user_mappings_on_gitlab_username'

    # Allow filtering by match method
    add_index :gitlab_user_mappings, :match_method, name: 'index_gitlab_user_mappings_on_match_method'
  end
end
