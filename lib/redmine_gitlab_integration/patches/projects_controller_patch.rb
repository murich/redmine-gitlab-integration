require_dependency 'projects_controller'

module RedmineGitlabIntegration
  module Patches
    module ProjectsControllerPatch
      def self.included(base)
        base.class_eval do
          before_action :fetch_gitlab_groups, only: [:new, :create]
          before_action :capture_gitlab_params, only: [:create]
          before_action :validate_gitlab_group, only: [:create]

          Rails.logger.info "[GITLAB DEBUG] ProjectsController patch applied with before_action"
        end
        Rails.logger.info "[GITLAB DEBUG] ProjectsController patch included"
      end

      def create
        Rails.logger.info "[GITLAB DEBUG] === PROJECTS CONTROLLER CREATE START ==="
        Rails.logger.info "[GITLAB DEBUG] Request method: #{request.method}"
        Rails.logger.info "[GITLAB DEBUG] Parameters: #{params.inspect}"
        
        # Log GitLab-specific parameters
        gitlab_project_param = params[:create_gitlab_project]
        gitlab_repository_param = params[:create_gitlab_repository]
        
        Rails.logger.info "[GITLAB DEBUG] create_gitlab_project param: #{gitlab_project_param.inspect}"
        Rails.logger.info "[GITLAB DEBUG] create_gitlab_repository param: #{gitlab_repository_param.inspect}"
        
        # Call original create method
        result = super
        
        Rails.logger.info "[GITLAB DEBUG] === PROJECTS CONTROLLER CREATE END ==="
        
        return result
      end

      private

      def fetch_gitlab_groups
        Rails.logger.info "[GITLAB DEBUG] Fetching GitLab groups for form"
        begin
          gitlab_service = RedmineGitlabIntegration::GitlabService.new
          @gitlab_groups = gitlab_service.list_groups
          Rails.logger.info "[GITLAB DEBUG] Fetched #{@gitlab_groups.count} groups"
        rescue => e
          Rails.logger.error "[GITLAB DEBUG] Error fetching groups: #{e.message}"
          @gitlab_groups = []
        end
      end

      def validate_gitlab_group
        Rails.logger.info "[GITLAB DEBUG] Validating GitLab group selection"
        Rails.logger.info "[GITLAB DEBUG] create_gitlab_repository: #{params[:create_gitlab_repository].inspect}"
        Rails.logger.info "[GITLAB DEBUG] gitlab_group_id: #{params[:gitlab_group_id].inspect}"

        # Check if GitLab repository creation is requested
        if params[:create_gitlab_repository].present?
          gitlab_group_id = params[:gitlab_group_id]

          if gitlab_group_id.blank?
            Rails.logger.error "[GITLAB DEBUG] Validation failed: GitLab group not selected"

            # Build project with submitted data to show errors
            @project = Project.new
            @project.safe_attributes = params[:project]
            @project.errors.add(:base, 'GitLab Group must be selected when creating a GitLab repository')

            # Prepare form data for re-rendering
            prepare_gitlab_form_data

            flash.now[:error] = 'GitLab Group must be selected when creating a GitLab repository'
            render action: 'new', status: :unprocessable_entity
            return # This halts the before_action chain
          end

          # If "new" group is selected, validate group name
          if gitlab_group_id == 'new' && params[:new_group_name].blank?
            Rails.logger.error "[GITLAB DEBUG] Validation failed: New group name not provided"

            @project = Project.new
            @project.safe_attributes = params[:project]
            @project.errors.add(:base, 'New Group Name is required when creating a new GitLab group')

            prepare_gitlab_form_data

            flash.now[:error] = 'New Group Name is required when creating a new GitLab group'
            render action: 'new', status: :unprocessable_entity
            return
          end

          Rails.logger.info "[GITLAB DEBUG] GitLab group validation passed: #{gitlab_group_id}"
        end
      end

      def prepare_gitlab_form_data
        # Fetch GitLab groups to populate dropdown
        begin
          gitlab_service = RedmineGitlabIntegration::GitlabService.new
          @gitlab_groups = gitlab_service.list_groups
          @selected_group_id = params[:gitlab_group_id]
        rescue => e
          Rails.logger.error "[GITLAB DEBUG] Error fetching groups for form: #{e.message}"
          @gitlab_groups = []
        end
      end

      def capture_gitlab_params
        Rails.logger.info "[GITLAB DEBUG] Capturing GitLab parameters from request"

        if params[:create_gitlab_project].present?
          Rails.logger.info "[GITLAB DEBUG] Setting @create_gitlab_project = true"
          @create_gitlab_project = true
        end

        if params[:create_gitlab_repository].present?
          Rails.logger.info "[GITLAB DEBUG] Setting @create_gitlab_repository = true"
          @create_gitlab_repository = true
        end

        # Capture group selection
        @gitlab_group_id = params[:gitlab_group_id]
        @new_group_name = params[:new_group_name]

        Rails.logger.info "[GITLAB DEBUG] Group ID: #{@gitlab_group_id}, New group name: #{@new_group_name}"

        # Store in project instance if it exists
        if @project
          @project.instance_variable_set(:@create_gitlab_project, @create_gitlab_project)
          @project.instance_variable_set(:@create_gitlab_repository, @create_gitlab_repository)
          @project.instance_variable_set(:@gitlab_group_id, @gitlab_group_id)
          @project.instance_variable_set(:@new_group_name, @new_group_name)
          Rails.logger.info "[GITLAB DEBUG] Stored GitLab params in project instance"
        end
      end
    end
  end
end

# Apply the patch
unless ProjectsController.included_modules.include?(RedmineGitlabIntegration::Patches::ProjectsControllerPatch)
  ProjectsController.send(:include, RedmineGitlabIntegration::Patches::ProjectsControllerPatch)
end