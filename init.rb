require 'redmine'

Redmine::Plugin.register :redmine_gitlab_integration do
  name 'Redmine GitLab Integration Plugin'
  description 'This plugin automatically creates GitLab projects and repositories when creating Redmine projects'
  version '1.0.0'

  # Add GoodJob dashboard to admin menu
  menu :admin_menu, :background_jobs, '/good_job',
       :caption => 'Background Jobs',
       :html => { :class => 'icon icon-list' },
       :if => Proc.new { User.current.admin? && defined?(GoodJob) }

  settings default: {
    'gitlab_url' => 'http://gitlab_app',
    'gitlab_token' => '',
    'gitlab_namespace' => ''
  }, partial: 'settings/gitlab_settings'
end

# Load hooks
require File.expand_path('../lib/redmine_gitlab_integration/hooks', __FILE__)

# Use to_prepare to ensure patches are applied before every request
# This is the correct way for Redmine plugins
Rails.configuration.to_prepare do
  # Load patches - to_prepare is called on every request in dev, once in production
  begin
    require_dependency File.expand_path('../lib/redmine_gitlab_integration/patches/project_patch', __FILE__)
    require_dependency File.expand_path('../lib/redmine_gitlab_integration/patches/projects_controller_patch', __FILE__)
    require_dependency File.expand_path('../lib/redmine_gitlab_integration/patches/members_controller_patch', __FILE__)

    Rails.logger.info "[GITLAB PLUGIN] Patches loaded successfully"
  rescue LoadError => e
    Rails.logger.error "[GITLAB PLUGIN] Failed to load patches: #{e.message}"
  end
end

# Member syncing now handled by MembersController patch (after_action callbacks)