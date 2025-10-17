# frozen_string_literal: true

class ManageGroupBadgeJob < ApplicationJob
  queue_as :default

  retry_on StandardError, wait: 5, attempts: 3

  def perform(action, gitlab_group_id, redmine_project_id = nil, old_group_id = nil)
    Rails.logger.info "[BADGE JOB] #{action} badge for GitLab group #{gitlab_group_id}"

    # Load GitlabService (explicit require for background job context)
    require_dependency 'redmine_gitlab_integration/gitlab_service'
    gitlab_service = RedmineGitlabIntegration::GitlabService.new

    case action
    when 'add', 'update'
      redmine_project = Project.find_by(id: redmine_project_id)
      unless redmine_project
        Rails.logger.error "[BADGE JOB] Redmine project #{redmine_project_id} not found"
        return
      end

      result = gitlab_service.add_redmine_badge_to_group(gitlab_group_id, redmine_project)
      Rails.logger.info "[BADGE JOB] Badge add result: #{result.inspect}"

    when 'remove'
      result = gitlab_service.remove_redmine_badge_from_group(gitlab_group_id)
      Rails.logger.info "[BADGE JOB] Badge remove result: #{result.inspect}"

    when 'migrate'
      # Remove from old group, add to new group
      if old_group_id
        gitlab_service.remove_redmine_badge_from_group(old_group_id)
        Rails.logger.info "[BADGE JOB] Removed badge from old group #{old_group_id}"
      end

      if redmine_project_id
        redmine_project = Project.find_by(id: redmine_project_id)
        if redmine_project
          gitlab_service.add_redmine_badge_to_group(gitlab_group_id, redmine_project)
          Rails.logger.info "[BADGE JOB] Added badge to new group #{gitlab_group_id}"
        end
      end
    end
  rescue => e
    Rails.logger.error "[BADGE JOB] Error in job: #{e.message}"
    raise
  end
end
