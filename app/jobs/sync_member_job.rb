# frozen_string_literal: true

# Background job for syncing individual Redmine member to GitLab group
# Handles add, update, remove, and recalculate operations asynchronously
class SyncMemberJob < ApplicationJob
  queue_as :default

  retry_on StandardError, wait: :exponentially_longer, attempts: 3

  # @param action [String] Action to perform: 'add', 'update', 'remove', 'recalculate'
  # @param gitlab_group_id [Integer] GitLab group ID
  # @param redmine_user_id [Integer] Redmine user ID
  # @param access_level [Integer] GitLab access level (30=Developer, 50=Owner, etc.)
  # @param exclude_project_id [Integer] Optional project ID to exclude from access calculation
  def perform(action, gitlab_group_id, redmine_user_id, access_level = nil, exclude_project_id = nil)
    Rails.logger.info "[MEMBER SYNC JOB] #{action} member #{redmine_user_id} for GitLab group #{gitlab_group_id}"

    # Find user
    user = User.find_by(id: redmine_user_id)
    unless user&.active?
      Rails.logger.warn "[MEMBER SYNC JOB] User #{redmine_user_id} not found or inactive"
      return
    end

    # Load GitlabService with absolute path
    require File.expand_path('../../../lib/redmine_gitlab_integration/gitlab_service', __FILE__)
    gitlab_service = RedmineGitlabIntegration::GitlabService.new

    # Find GitLab user ID
    gitlab_user_id = gitlab_service.find_gitlab_user_id(user)
    unless gitlab_user_id
      Rails.logger.warn "[MEMBER SYNC JOB] No GitLab user found for Redmine user #{user.login}"
      return
    end

    case action
    when 'add'
      handle_add(gitlab_service, gitlab_group_id, gitlab_user_id, user, access_level)

    when 'update'
      handle_update(gitlab_service, gitlab_group_id, gitlab_user_id, user, access_level)

    when 'remove'
      handle_remove(gitlab_service, gitlab_group_id, gitlab_user_id, user)

    when 'recalculate'
      handle_recalculate(gitlab_service, gitlab_group_id, gitlab_user_id, user, exclude_project_id)

    else
      Rails.logger.error "[MEMBER SYNC JOB] Unknown action: #{action}"
    end

  rescue => e
    Rails.logger.error "[MEMBER SYNC JOB] Error in job: #{e.message}"
    Rails.logger.error e.backtrace.first(5).join("\n")
    raise
  end

  private

  def handle_add(gitlab_service, gitlab_group_id, gitlab_user_id, user, access_level)
    Rails.logger.info "[MEMBER SYNC JOB] Adding user #{user.login} to group #{gitlab_group_id} with access level #{access_level}"

    result = gitlab_service.add_group_member(gitlab_group_id, gitlab_user_id, access_level)

    if result[:success]
      Rails.logger.info "[MEMBER SYNC JOB] Successfully added member #{user.login}"
    else
      Rails.logger.error "[MEMBER SYNC JOB] Failed to add member: #{result[:error]}"
      raise StandardError, "Failed to add member: #{result[:error]}"
    end
  end

  def handle_update(gitlab_service, gitlab_group_id, gitlab_user_id, user, access_level)
    Rails.logger.info "[MEMBER SYNC JOB] Updating user #{user.login} access level to #{access_level}"

    result = gitlab_service.update_group_member(gitlab_group_id, gitlab_user_id, access_level)

    if result[:success]
      Rails.logger.info "[MEMBER SYNC JOB] Successfully updated member #{user.login}"
    else
      Rails.logger.error "[MEMBER SYNC JOB] Failed to update member: #{result[:error]}"
      raise StandardError, "Failed to update member: #{result[:error]}"
    end
  end

  def handle_remove(gitlab_service, gitlab_group_id, gitlab_user_id, user)
    Rails.logger.info "[MEMBER SYNC JOB] Removing user #{user.login} from group #{gitlab_group_id}"

    result = gitlab_service.remove_group_member(gitlab_group_id, gitlab_user_id)

    if result[:success]
      Rails.logger.info "[MEMBER SYNC JOB] Successfully removed member #{user.login}"
    else
      Rails.logger.error "[MEMBER SYNC JOB] Failed to remove member: #{result[:error]}"
      # Don't raise error for remove - if user isn't in group, that's okay
    end
  end

  def handle_recalculate(gitlab_service, gitlab_group_id, gitlab_user_id, user, exclude_project_id)
    Rails.logger.info "[MEMBER SYNC JOB] Recalculating access level for user #{user.login} (excluding project #{exclude_project_id})"

    # Calculate access level across all projects in this group (excluding specified project)
    access_level = calculate_user_access_level(user, gitlab_group_id, exclude_project_id)

    if access_level.nil?
      # User has no remaining access - remove from group
      Rails.logger.info "[MEMBER SYNC JOB] User has no remaining access, removing from group"
      handle_remove(gitlab_service, gitlab_group_id, gitlab_user_id, user)
    else
      # User still has access - update to new level
      Rails.logger.info "[MEMBER SYNC JOB] User still has access level #{access_level}, updating"
      handle_update(gitlab_service, gitlab_group_id, gitlab_user_id, user, access_level)
    end
  end

  def calculate_user_access_level(user, gitlab_group_id, exclude_project_id)
    # Find all Redmine projects mapped to this GitLab group
    project_ids = GitlabMapping.where(gitlab_group_id: gitlab_group_id).pluck(:redmine_project_id)

    # Exclude specified project if provided
    project_ids -= [exclude_project_id] if exclude_project_id

    return nil if project_ids.empty?

    # Get all roles for this user across these projects
    all_role_names = Member.joins(:roles)
                           .where(user_id: user.id, project_id: project_ids)
                           .pluck('roles.name')
                           .uniq
                           .map(&:downcase)

    Rails.logger.info "[MEMBER SYNC JOB] User #{user.login} roles across group projects: #{all_role_names.inspect}"

    # Map to highest access level (same logic as member_patch.rb)
    return 50 if all_role_names.any? { |name| name.include?('manager') || name.include?('admin') }
    return 30 if all_role_names.any? { |name| name.include?('developer') }
    return 20 if all_role_names.any? { |name| name.include?('reporter') }

    # If user has memberships but no recognized roles, return nil (remove from GitLab)
    nil
  end
end
