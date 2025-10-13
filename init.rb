require 'redmine'

Redmine::Plugin.register :redmine_gitlab_integration do
  name 'Redmine GitLab Integration Plugin'
  description 'This plugin automatically creates GitLab projects and repositories when creating Redmine projects'
  version '1.0.0'
  
  menu :project_menu, :gitlab_projects, { :controller => 'gitlab_projects', :action => 'index' }, 
       :caption => 'GitLab Projects', :after => :repositories, :param => :project_id
  
  project_module :gitlab_integration do
    permission :create_gitlab_projects, :gitlab_projects => [:create]
    permission :view_gitlab_projects, :gitlab_projects => [:index, :show]
  end
  
  settings default: {
    'gitlab_url' => 'http://gitlab_app',
    'gitlab_token' => '',
    'gitlab_namespace' => ''
  }, partial: 'settings/gitlab_settings'
end

# Load hooks
require File.expand_path('../lib/redmine_gitlab_integration/hooks', __FILE__)

Rails.application.config.after_initialize do
  begin
    require File.expand_path('../lib/redmine_gitlab_integration/patches/project_patch', __FILE__)
    require File.expand_path('../lib/redmine_gitlab_integration/patches/projects_controller_patch', __FILE__)
    require File.expand_path('../lib/redmine_gitlab_integration/patches/member_patch', __FILE__)
  rescue LoadError => e
    Rails.logger.warn "GitLab integration plugin files not found: #{e.message}"
  end
end