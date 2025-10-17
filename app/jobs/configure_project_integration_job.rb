# frozen_string_literal: true

class ConfigureProjectIntegrationJob < ApplicationJob
  queue_as :default

  retry_on StandardError, wait: 5, attempts: 3

  def perform(gitlab_project_id, redmine_project_id)
    Rails.logger.info "[INTEGRATION JOB] Configuring Redmine integration for GitLab project #{gitlab_project_id}"

    redmine_project = Project.find_by(id: redmine_project_id)
    unless redmine_project
      Rails.logger.error "[INTEGRATION JOB] Redmine project #{redmine_project_id} not found"
      return
    end

    # Load GitlabService (explicit require for background job context)
    require_dependency 'redmine_gitlab_integration/gitlab_service'
    gitlab_service = RedmineGitlabIntegration::GitlabService.new

    # Configure integration
    result = gitlab_service.configure_redmine_integration(gitlab_project_id, redmine_project)

    if result[:success]
      Rails.logger.info "[INTEGRATION JOB] Successfully configured project integration"
    else
      Rails.logger.error "[INTEGRATION JOB] Failed to configure project integration: #{result[:error]}"
      raise StandardError, "Failed to configure project integration: #{result[:error]}"
    end
  rescue => e
    Rails.logger.error "[INTEGRATION JOB] Error in job: #{e.message}"
    raise
  end
end
