require_dependency 'member'

# Ensure SyncMemberJob is loaded
begin
  require File.expand_path('../../../../app/jobs/sync_member_job', __FILE__)
rescue LoadError => e
  Rails.logger.error "[GITLAB PLUGIN] Failed to load SyncMemberJob: #{e.message}"
end

module RedmineGitlabIntegration
  module Patches
    module MemberPatch
      def self.included(base)
        base.class_eval do
          after_create :sync_member_to_gitlab
          after_destroy :sync_member_removal_from_gitlab
          after_update :sync_member_update_to_gitlab
        end
      end

      private

      def sync_member_to_gitlab
        return unless user&.active? && project

        begin
          Rails.logger.info "[GITLAB MEMBER SYNC] ========== CALLBACK FIRED =========="
          Rails.logger.info "[GITLAB MEMBER SYNC] Member added: #{user.login} to project #{project.name}"

          # Check if project has GitLab integration
          gitlab_mapping = GitlabMapping.find_by(redmine_project_id: project.id)
          unless gitlab_mapping&.gitlab_group_id
            Rails.logger.info "[GITLAB MEMBER SYNC] Project has no GitLab group, skipping"
            return
          end

          gitlab_group_id = gitlab_mapping.gitlab_group_id
          Rails.logger.info "[GITLAB MEMBER SYNC] Queueing sync to GitLab group #{gitlab_group_id}"

          # Calculate appropriate access level for user across all projects in this group
          access_level = calculate_user_access_level_for_group(user, gitlab_group_id)

          # Execute asynchronously in a background thread
          Thread.new do
            begin
              SyncMemberJob.new.perform('add', gitlab_group_id, user.id, access_level)
              Rails.logger.info "[GITLAB MEMBER SYNC] Completed async add for user #{user.login}"
            rescue => e
              Rails.logger.error "[GITLAB MEMBER SYNC] Error in async add: #{e.message}"
              Rails.logger.error e.backtrace.first(3).join("\n")
            end
          end
          Rails.logger.info "[GITLAB MEMBER SYNC] Started async add for user #{user.login} with access level #{access_level}"

        rescue => e
          Rails.logger.error "[GITLAB MEMBER SYNC] Error queueing member sync: #{e.message}"
          Rails.logger.error e.backtrace.first(3).join("\n")
        end
      end

      def sync_member_removal_from_gitlab
        return unless user&.active? && project

        begin
          Rails.logger.info "[GITLAB MEMBER SYNC] Member removed: #{user.login} from project #{project.name}"

          # Check if project has GitLab integration
          gitlab_mapping = GitlabMapping.find_by(redmine_project_id: project.id)
          unless gitlab_mapping&.gitlab_group_id
            Rails.logger.info "[GITLAB MEMBER SYNC] Project has no GitLab group, skipping"
            return
          end

          gitlab_group_id = gitlab_mapping.gitlab_group_id

          # Check if user still has access to this GitLab group through other projects
          if user_has_access_to_group?(user, gitlab_group_id, exclude_project: project)
            # User still has access via other projects - recalculate their access level
            Thread.new do
              begin
                SyncMemberJob.new.perform('recalculate', gitlab_group_id, user.id, nil, project.id)
                Rails.logger.info "[GITLAB MEMBER SYNC] Completed async recalculate for user #{user.login}"
              rescue => e
                Rails.logger.error "[GITLAB MEMBER SYNC] Error in async recalculate: #{e.message}"
                Rails.logger.error e.backtrace.first(3).join("\n")
              end
            end
            Rails.logger.info "[GITLAB MEMBER SYNC] Started async recalculate for user #{user.login}"
          else
            # User has no remaining access to this group - remove from GitLab
            Thread.new do
              begin
                SyncMemberJob.new.perform('remove', gitlab_group_id, user.id)
                Rails.logger.info "[GITLAB MEMBER SYNC] Completed async removal for user #{user.login}"
              rescue => e
                Rails.logger.error "[GITLAB MEMBER SYNC] Error in async removal: #{e.message}"
                Rails.logger.error e.backtrace.first(3).join("\n")
              end
            end
            Rails.logger.info "[GITLAB MEMBER SYNC] Started async removal for user #{user.login} from group #{gitlab_group_id}"
          end

        rescue => e
          Rails.logger.error "[GITLAB MEMBER SYNC] Error queueing member removal sync: #{e.message}"
          Rails.logger.error e.backtrace.first(3).join("\n")
        end
      end

      def sync_member_update_to_gitlab
        # Sync member role updates to GitLab
        return unless user&.active? && project

        begin
          Rails.logger.info "[GITLAB MEMBER SYNC] Member roles updated: #{user.login} in project #{project.name}"

          # Check if project has GitLab integration
          gitlab_mapping = GitlabMapping.find_by(redmine_project_id: project.id)
          unless gitlab_mapping&.gitlab_group_id
            Rails.logger.info "[GITLAB MEMBER SYNC] Project has no GitLab group, skipping"
            return
          end

          gitlab_group_id = gitlab_mapping.gitlab_group_id

          # Calculate new access level across all projects
          new_access_level = calculate_user_access_level_for_group(user, gitlab_group_id)

          # Execute asynchronously in a background thread
          Thread.new do
            begin
              SyncMemberJob.new.perform('update', gitlab_group_id, user.id, new_access_level)
              Rails.logger.info "[GITLAB MEMBER SYNC] Completed async update for user #{user.login}"
            rescue => e
              Rails.logger.error "[GITLAB MEMBER SYNC] Error in async update: #{e.message}"
              Rails.logger.error e.backtrace.first(3).join("\n")
            end
          end
          Rails.logger.info "[GITLAB MEMBER SYNC] Started async update for user #{user.login} to access level #{new_access_level}"

        rescue => e
          Rails.logger.error "[GITLAB MEMBER SYNC] Error queueing member update sync: #{e.message}"
          Rails.logger.error e.backtrace.first(3).join("\n")
        end
      end

      # Check if user has access to a GitLab group through any Redmine project
      # @param user [User] The user to check
      # @param gitlab_group_id [Integer] The GitLab group ID
      # @param exclude_project [Project, nil] Optional project to exclude from check
      # @return [Boolean] True if user has access
      def user_has_access_to_group?(user, gitlab_group_id, exclude_project: nil)
        # Find all Redmine projects mapped to this GitLab group
        project_ids = GitlabMapping.where(gitlab_group_id: gitlab_group_id).pluck(:redmine_project_id)

        # Exclude specified project if provided
        project_ids -= [exclude_project.id] if exclude_project

        return false if project_ids.empty?

        # Check if user is a member of any of these projects
        Member.joins(:project)
              .where(user_id: user.id, project_id: project_ids)
              .where.not(id: self.id) # Exclude current member record
              .exists?
      end

      # Calculate the highest access level a user should have in a GitLab group
      # based on their roles across all Redmine projects mapped to that group
      # @param user [User] The user
      # @param gitlab_group_id [Integer] The GitLab group ID
      # @param exclude_project [Project, nil] Optional project to exclude from calculation
      # @return [Integer] GitLab access level (50=Owner, 30=Developer, 20=Reporter)
      def calculate_user_access_level_for_group(user, gitlab_group_id, exclude_project: nil)
        # Find all Redmine projects mapped to this GitLab group
        project_ids = GitlabMapping.where(gitlab_group_id: gitlab_group_id).pluck(:redmine_project_id)

        # Exclude specified project if provided
        project_ids -= [exclude_project.id] if exclude_project

        return 30 if project_ids.empty? # Default to Developer

        # Get all roles for this user across these projects
        all_role_names = Member.joins(:roles)
                               .where(user_id: user.id, project_id: project_ids)
                               .pluck('roles.name')
                               .uniq
                               .map(&:downcase)

        Rails.logger.info "[GITLAB MEMBER SYNC] User #{user.login} roles across group projects: #{all_role_names.inspect}"

        # Map to highest access level (same logic as GitlabService)
        return 50 if all_role_names.any? { |name| name.include?('manager') || name.include?('admin') }
        return 30 if all_role_names.any? { |name| name.include?('developer') }
        return 20 if all_role_names.any? { |name| name.include?('reporter') }

        # Default to Developer
        30
      end
    end
  end
end

# Apply the patch to Member model
unless Member.included_modules.include?(RedmineGitlabIntegration::Patches::MemberPatch)
  Member.send(:include, RedmineGitlabIntegration::Patches::MemberPatch)
  Rails.logger.info "[GITLAB PLUGIN] Member patch applied from member_patch.rb - callbacks registered"
end
