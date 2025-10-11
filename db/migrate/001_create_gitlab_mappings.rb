class CreateGitlabMappings < ActiveRecord::Migration[6.1]
  def change
    create_table :gitlab_mappings do |t|
      t.integer :redmine_project_id, null: false
      t.integer :gitlab_group_id
      t.integer :gitlab_project_id
      t.string :mapping_type # 'group', 'project', 'inherited'
      t.timestamps
    end

    add_index :gitlab_mappings, :redmine_project_id, unique: true
    add_index :gitlab_mappings, :gitlab_group_id
    add_index :gitlab_mappings, :gitlab_project_id
  end
end
