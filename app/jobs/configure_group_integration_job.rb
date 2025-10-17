# frozen_string_literal: true

class ConfigureGroupIntegrationJob < ApplicationJob
  queue_as :default

  retry_on StandardError, wait: 5, attempts: 3

  def perform(gitlab_group_id, redmine_project_id)
    Rails.logger.info "[GROUP INTEGRATION JOB] Configuring group-level Redmine integration for GitLab group #{gitlab_group_id}"

    redmine_project = Project.find_by(id: redmine_project_id)
    unless redmine_project
      Rails.logger.error "[GROUP INTEGRATION JOB] Redmine project #{redmine_project_id} not found"
      return
    end

    # Load GitlabService (explicit require for background job context)
    require_dependency 'redmine_gitlab_integration/gitlab_service'
    gitlab_service = RedmineGitlabIntegration::GitlabService.new

    # Configure group-level integration
    result = gitlab_service.configure_group_redmine_integration(gitlab_group_id, redmine_project)

    if result[:success]
      Rails.logger.info "[GROUP INTEGRATION JOB] Successfully configured group integration"
    else
      Rails.logger.error "[GROUP INTEGRATION JOB] Failed to configure group integration: #{result[:error]}"
      raise StandardError, "Failed to configure group integration: #{result[:error]}"
    end
  rescue => e
    Rails.logger.error "[GROUP INTEGRATION JOB] Error in job: #{e.message}"
    raise
  end
end
