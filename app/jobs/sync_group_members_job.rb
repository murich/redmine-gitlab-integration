# frozen_string_literal: true

class SyncGroupMembersJob < ApplicationJob
  queue_as :default

  retry_on StandardError, wait: :exponentially_longer, attempts: 3

  def perform(gitlab_group_id, redmine_project_id)
    Rails.logger.info "[MEMBER SYNC JOB] Syncing members for GitLab group #{gitlab_group_id}"

    redmine_project = Project.find_by(id: redmine_project_id)
    unless redmine_project
      Rails.logger.error "[MEMBER SYNC JOB] Redmine project #{redmine_project_id} not found"
      return
    end

    # Load GitlabService (gets config from ENV automatically)
    require_dependency 'redmine_gitlab_integration/gitlab_service'
    gitlab_service = RedmineGitlabIntegration::GitlabService.new

    # Sync members
    result = gitlab_service.sync_project_members(gitlab_group_id, redmine_project)

    Rails.logger.info "[MEMBER SYNC JOB] Member sync complete: #{result.inspect}"
  rescue => e
    Rails.logger.error "[MEMBER SYNC JOB] Error in job: #{e.message}"
    raise
  end
end
