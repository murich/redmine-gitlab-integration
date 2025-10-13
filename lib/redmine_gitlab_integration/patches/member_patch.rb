require_dependency 'member'

module RedmineGitlabIntegration
  module Patches
    module MemberPatch
      def self.included(base)
        base.class_eval do
          after_create :sync_member_to_gitlab
          after_destroy :sync_member_removal_from_gitlab
          after_update :sync_member_update_to_gitlab

          Rails.logger.info "[GITLAB MEMBER PATCH] Member callbacks registered"
        end
      end

      private

      def sync_member_to_gitlab
        return unless user&.active? && project

        begin
          Rails.logger.info "[GITLAB MEMBER SYNC] Member added: #{user.login} to project #{project.name}"

          # Check if project has GitLab integration
          gitlab_mapping = GitlabMapping.find_by(redmine_project_id: project.id)
          unless gitlab_mapping&.gitlab_group_id
            Rails.logger.info "[GITLAB MEMBER SYNC] Project has no GitLab group, skipping"
            return
          end

          gitlab_group_id = gitlab_mapping.gitlab_group_id
          Rails.logger.info "[GITLAB MEMBER SYNC] Syncing to GitLab group #{gitlab_group_id}"

          # Calculate appropriate access level for user across all projects in this group
          access_level = calculate_user_access_level_for_group(user, gitlab_group_id)

          # Add or update member in GitLab
          gitlab_service = RedmineGitlabIntegration::GitlabService.new
          gitlab_user_id = gitlab_service.find_gitlab_user_id(user)

          unless gitlab_user_id
            Rails.logger.warn "[GITLAB MEMBER SYNC] No GitLab user found for #{user.login}"
            return
          end

          result = gitlab_service.add_group_member(gitlab_group_id, gitlab_user_id, access_level)
          if result[:success]
            Rails.logger.info "[GITLAB MEMBER SYNC] Successfully synced member #{user.login} to group #{gitlab_group_id}"
          else
            Rails.logger.error "[GITLAB MEMBER SYNC] Failed to sync member: #{result[:error]}"
          end

        rescue => e
          Rails.logger.error "[GITLAB MEMBER SYNC] Error syncing member addition: #{e.message}"
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
            # User still has access via other projects - recalculate access level
            new_access_level = calculate_user_access_level_for_group(user, gitlab_group_id, exclude_project: project)
            Rails.logger.info "[GITLAB MEMBER SYNC] User still has access via other projects, updating access level to #{new_access_level}"

            gitlab_service = RedmineGitlabIntegration::GitlabService.new
            gitlab_user_id = gitlab_service.find_gitlab_user_id(user)

            if gitlab_user_id
              gitlab_service.update_group_member(gitlab_group_id, gitlab_user_id, new_access_level)
            end
          else
            # User has no remaining access to this group - remove them
            Rails.logger.info "[GITLAB MEMBER SYNC] User has no remaining access to group #{gitlab_group_id}, removing"

            gitlab_service = RedmineGitlabIntegration::GitlabService.new
            gitlab_user_id = gitlab_service.find_gitlab_user_id(user)

            if gitlab_user_id
              result = gitlab_service.remove_group_member(gitlab_group_id, gitlab_user_id)
              if result[:success]
                Rails.logger.info "[GITLAB MEMBER SYNC] Successfully removed member #{user.login} from group #{gitlab_group_id}"
              else
                Rails.logger.error "[GITLAB MEMBER SYNC] Failed to remove member: #{result[:error]}"
              end
            end
          end

        rescue => e
          Rails.logger.error "[GITLAB MEMBER SYNC] Error syncing member removal: #{e.message}"
          Rails.logger.error e.backtrace.first(3).join("\n")
        end
      end

      def sync_member_update_to_gitlab
        # Only sync if roles changed
        return unless saved_change_to_role_ids? && user&.active? && project

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
          Rails.logger.info "[GITLAB MEMBER SYNC] Updating access level to #{new_access_level}"

          # Update member in GitLab
          gitlab_service = RedmineGitlabIntegration::GitlabService.new
          gitlab_user_id = gitlab_service.find_gitlab_user_id(user)

          unless gitlab_user_id
            Rails.logger.warn "[GITLAB MEMBER SYNC] No GitLab user found for #{user.login}"
            return
          end

          result = gitlab_service.update_group_member(gitlab_group_id, gitlab_user_id, new_access_level)
          if result[:success]
            Rails.logger.info "[GITLAB MEMBER SYNC] Successfully updated member #{user.login} access level"
          else
            Rails.logger.error "[GITLAB MEMBER SYNC] Failed to update member: #{result[:error]}"
          end

        rescue => e
          Rails.logger.error "[GITLAB MEMBER SYNC] Error syncing member update: #{e.message}"
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

# Apply the patch
unless Member.included_modules.include?(RedmineGitlabIntegration::Patches::MemberPatch)
  Member.send(:include, RedmineGitlabIntegration::Patches::MemberPatch)
end
