get 'gitlab_mappings', to: 'gitlab_mappings#index'
get 'gitlab_mappings/data', to: 'gitlab_mappings#graph_data'
post 'gitlab_mappings/update', to: 'gitlab_mappings#update'
get 'gitlab_mappings/fetch_parent_group', to: 'gitlab_mappings#fetch_parent_group'
get 'gitlab_groups', to: 'gitlab_groups#index'
get 'gitlab_groups/:group_id/orphan_projects', to: 'gitlab_groups#orphan_projects'

# Mount GoodJob dashboard for background job management
# Note: Admin check is done in the menu item (:if proc in init.rb)
# Route constraints don't work well with User.current in Redmine
if defined?(GoodJob)
  mount GoodJob::Engine => 'good_job'
end
