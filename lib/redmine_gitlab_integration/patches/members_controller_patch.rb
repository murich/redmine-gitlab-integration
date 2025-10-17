require_dependency 'members_controller'

module RedmineGitlabIntegration
  module Patches
    module MembersControllerPatch
      def self.included(base)
        base.class_eval do
          after_action :sync_member_to_gitlab, only: [:create]
          after_action :sync_member_update_to_gitlab, only: [:update]
          after_action :sync_member_removal_from_gitlab, only: [:destroy]
        end
      end

      private

      def sync_member_to_gitlab
        return unless @member&.persisted? && @member.user&.active? && @project

        begin
          Rails.logger.info "[GITLAB MEMBER SYNC] Member added: #{@member.user.login} to project #{@project.name}"

          # Check if project has GitLab integration
          gitlab_mapping = GitlabMapping.find_by(redmine_project_id: @project.id)
          unless gitlab_mapping&.gitlab_group_id
            Rails.logger.info "[GITLAB MEMBER SYNC] Project has no GitLab group, skipping"
            return
          end

          gitlab_group_id = gitlab_mapping.gitlab_group_id
          access_level = calculate_gitlab_access_level(@member)

          # Execute asynchronously in a background thread
          Thread.new do
            begin
              SyncMemberJob.new.perform('add', gitlab_group_id, @member.user.id, access_level)
              Rails.logger.info "[GITLAB MEMBER SYNC] Completed async add for user #{@member.user.login}"
            rescue => e
              Rails.logger.error "[GITLAB MEMBER SYNC] Error in async add: #{e.message}"
              Rails.logger.error e.backtrace.first(3).join("\n")
            end
          end
          Rails.logger.info "[GITLAB MEMBER SYNC] Started async add for user #{@member.user.login} with access level #{access_level}"

        rescue => e
          Rails.logger.error "[GITLAB MEMBER SYNC] Error queueing member sync: #{e.message}"
          Rails.logger.error e.backtrace.first(3).join("\n")
        end
      end

      def sync_member_update_to_gitlab
        return unless @member&.persisted? && @member.user&.active? && @project

        begin
          Rails.logger.info "[GITLAB MEMBER SYNC] Member updated: #{@member.user.login} in project #{@project.name}"

          # Check if project has GitLab integration
          gitlab_mapping = GitlabMapping.find_by(redmine_project_id: @project.id)
          unless gitlab_mapping&.gitlab_group_id
            Rails.logger.info "[GITLAB MEMBER SYNC] Project has no GitLab group, skipping"
            return
          end

          gitlab_group_id = gitlab_mapping.gitlab_group_id
          new_access_level = calculate_gitlab_access_level(@member)

          # Execute asynchronously in a background thread
          Thread.new do
            begin
              SyncMemberJob.new.perform('update', gitlab_group_id, @member.user.id, new_access_level)
              Rails.logger.info "[GITLAB MEMBER SYNC] Completed async update for user #{@member.user.login}"
            rescue => e
              Rails.logger.error "[GITLAB MEMBER SYNC] Error in async update: #{e.message}"
              Rails.logger.error e.backtrace.first(3).join("\n")
            end
          end
          Rails.logger.info "[GITLAB MEMBER SYNC] Started async update for user #{@member.user.login} to access level #{new_access_level}"

        rescue => e
          Rails.logger.error "[GITLAB MEMBER SYNC] Error queueing member update sync: #{e.message}"
          Rails.logger.error e.backtrace.first(3).join("\n")
        end
      end

      def sync_member_removal_from_gitlab
        return unless @member && @member.user&.active? && @project

        begin
          Rails.logger.info "[GITLAB MEMBER SYNC] Member removed: #{@member.user.login} from project #{@project.name}"

          # Check if project has GitLab integration
          gitlab_mapping = GitlabMapping.find_by(redmine_project_id: @project.id)
          unless gitlab_mapping&.gitlab_group_id
            Rails.logger.info "[GITLAB MEMBER SYNC] Project has no GitLab group, skipping"
            return
          end

          gitlab_group_id = gitlab_mapping.gitlab_group_id

          # Execute asynchronously in a background thread
          Thread.new do
            begin
              SyncMemberJob.new.perform('remove', gitlab_group_id, @member.user.id)
              Rails.logger.info "[GITLAB MEMBER SYNC] Completed async removal for user #{@member.user.login}"
            rescue => e
              Rails.logger.error "[GITLAB MEMBER SYNC] Error in async removal: #{e.message}"
              Rails.logger.error e.backtrace.first(3).join("\n")
            end
          end
          Rails.logger.info "[GITLAB MEMBER SYNC] Started async removal for user #{@member.user.login} from group #{gitlab_group_id}"

        rescue => e
          Rails.logger.error "[GITLAB MEMBER SYNC] Error queueing member removal sync: #{e.message}"
          Rails.logger.error e.backtrace.first(3).join("\n")
        end
      end

      def calculate_gitlab_access_level(member)
        role_names = member.roles.map(&:name).map(&:downcase)
        Rails.logger.info "[GITLAB MEMBER SYNC] User #{member.user.login} roles: #{role_names.inspect}"

        return 50 if role_names.any? { |name| name.include?('manager') || name.include?('admin') }
        return 30 if role_names.any? { |name| name.include?('developer') }
        return 20 if role_names.any? { |name| name.include?('reporter') }

        30 # Default to Developer
      end
    end
  end
end

# Apply the patch
unless MembersController.included_modules.include?(RedmineGitlabIntegration::Patches::MembersControllerPatch)
  MembersController.send(:include, RedmineGitlabIntegration::Patches::MembersControllerPatch)
  Rails.logger.info "[GITLAB PLUGIN] MembersController patch applied - after_actions registered"
end
