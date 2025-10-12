require_dependency 'projects_controller'

module RedmineGitlabIntegration
  module Patches
    module ProjectsControllerPatch
      def self.included(base)
        base.class_eval do
          before_action :fetch_gitlab_groups, only: [:new, :create, :edit, :settings]
          before_action :load_current_gitlab_mapping, only: [:edit, :settings]
          before_action :capture_gitlab_params, only: [:create, :update]
          before_action :validate_gitlab_group, only: [:create, :update]
          after_action :save_gitlab_group_mapping, only: [:create, :update]

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

      def load_current_gitlab_mapping
        return unless @project

        mapping = GitlabMapping.find_by(redmine_project_id: @project.id)
        if mapping
          @selected_group_id = mapping.gitlab_group_id
          @selected_project_id = mapping.gitlab_project_id

          # Fetch names from GitLab for better UI display
          begin
            gitlab_service = RedmineGitlabIntegration::GitlabService.new

            # Get group name
            if @selected_group_id.present?
              groups = gitlab_service.list_groups
              selected_group = groups.find { |g| g['id'].to_s == @selected_group_id.to_s }
              @selected_group_name = selected_group ? selected_group['name'] : "Group ##{@selected_group_id}"
            end

            # Get project name
            if @selected_project_id.present? && @selected_group_id.present?
              projects = gitlab_service.list_group_projects(@selected_group_id)
              selected_project = projects.find { |p| p['id'].to_s == @selected_project_id.to_s }
              @selected_project_name = selected_project ? selected_project['name'] : "Project ##{@selected_project_id}"
            end
          rescue => e
            Rails.logger.error "[GITLAB DEBUG] Error fetching names: #{e.message}"
            @selected_group_name = "Group ##{@selected_group_id}"
            @selected_project_name = "Project ##{@selected_project_id}"
          end

          Rails.logger.info "[GITLAB DEBUG] Loaded existing mapping: group=#{@selected_group_id} (#{@selected_group_name}), project=#{@selected_project_id} (#{@selected_project_name})"
        end
      end

      def save_gitlab_group_mapping
        Rails.logger.info "[GITLAB DEBUG] save_gitlab_group_mapping called"
        Rails.logger.info "[GITLAB DEBUG] @project=#{@project&.id}, @gitlab_group_id=#{@gitlab_group_id.inspect}, @gitlab_project_id=#{@gitlab_project_id.inspect}"

        return unless @project && !@project.errors.any? && @gitlab_group_id.present?

        Rails.logger.info "[GITLAB DEBUG] Saving GitLab group mapping: project=#{@project.id}, group=#{@gitlab_group_id}"

        mapping = GitlabMapping.find_or_initialize_by(redmine_project_id: @project.id)
        mapping.gitlab_group_id = @gitlab_group_id
        mapping.mapping_type = 'group'

        # Handle GitLab project creation or linking if requested
        # Skip if user selected "Don't create" (empty string)
        if @gitlab_project_id.present?
          handle_gitlab_project_linkage(mapping)
        end

        if mapping.save
          Rails.logger.info "[GITLAB DEBUG] Successfully saved GitLab mapping: #{mapping.inspect}"
        else
          Rails.logger.error "[GITLAB DEBUG] Failed to save GitLab mapping: #{mapping.errors.full_messages.join(', ')}"
        end
      end

      def handle_gitlab_project_linkage(mapping)
        gitlab_service = RedmineGitlabIntegration::GitlabService.new

        if @gitlab_project_id == 'new'
          # Create new GitLab project (without README - repo is created empty)
          Rails.logger.info "[GITLAB DEBUG] Creating new GitLab project in group #{@gitlab_group_id}"
          result = gitlab_service.create_project_in_group(
            @gitlab_group_id,
            @project.name,
            @project.description || '',
            false,  # initialize_with_readme: false (empty repo)
            @project.is_public?
          )

          if result[:success]
            mapping.gitlab_project_id = result[:project_id]
            Rails.logger.info "[GITLAB DEBUG] Created new GitLab project: #{result[:project_id]}"

            # Fetch the created project to get its creation timestamp from GitLab
            gitlab_project = gitlab_service.get_project(result[:project_id])
            if gitlab_project && gitlab_project['created_at']
              created_at_timestamp = Time.parse(gitlab_project['created_at']).to_i
              Rails.logger.info "[GITLAB DEBUG] GitLab project created at: #{Time.at(created_at_timestamp)}"

              # Enqueue background job to sync repository asynchronously
              # Use GitLab's creation timestamp to find repos created after that
              Rails.logger.info "[GITLAB DEBUG] Enqueuing SyncGitlabRepositoryJob for project #{@project.id}, GitLab project #{result[:project_id]}"
              SyncGitlabRepositoryJob.perform_later(@project.id, result[:project_id], 1, created_at_timestamp)
            else
              Rails.logger.error "[GITLAB DEBUG] Could not fetch GitLab project creation timestamp"
            end
          else
            Rails.logger.error "[GITLAB DEBUG] Failed to create GitLab project: #{result[:error]}"
          end
        else
          # Link to existing GitLab project
          mapping.gitlab_project_id = @gitlab_project_id.to_i
          Rails.logger.info "[GITLAB DEBUG] Linking to existing GitLab project: #{@gitlab_project_id}"

          # Fetch the existing project to get its creation timestamp from GitLab
          gitlab_project = gitlab_service.get_project(@gitlab_project_id.to_i)
          if gitlab_project && gitlab_project['created_at']
            created_at_timestamp = Time.parse(gitlab_project['created_at']).to_i
            Rails.logger.info "[GITLAB DEBUG] Existing GitLab project created at: #{Time.at(created_at_timestamp)}"

            # Enqueue background job to sync repository asynchronously
            # For existing projects, repo should be ready immediately, but use background job for consistency
            Rails.logger.info "[GITLAB DEBUG] Enqueuing SyncGitlabRepositoryJob for existing project #{@project.id}, GitLab project #{@gitlab_project_id}"
            SyncGitlabRepositoryJob.perform_later(@project.id, @gitlab_project_id.to_i, 1, created_at_timestamp)
          else
            Rails.logger.error "[GITLAB DEBUG] Could not fetch GitLab project creation timestamp for existing project"
          end
        end
      rescue => e
        Rails.logger.error "[GITLAB DEBUG] Error handling GitLab project: #{e.message}"
        Rails.logger.error e.backtrace.first(5).join("\n")
      end


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
        Rails.logger.info "[GITLAB DEBUG] gitlab_group_id: #{params[:gitlab_group_id].inspect}"

        gitlab_group_id = params[:gitlab_group_id]

        if gitlab_group_id.blank?
          Rails.logger.error "[GITLAB DEBUG] Validation failed: GitLab group not selected"

          # Build project with submitted data to show errors
          @project = Project.new
          @project.safe_attributes = params[:project]
          @project.errors.add(:base, 'GitLab Group must be selected')

          # Prepare form data for re-rendering
          prepare_gitlab_form_data

          flash.now[:error] = 'GitLab Group must be selected'
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

        # Capture group and project selection
        @gitlab_group_id = params[:gitlab_group_id]
        @new_group_name = params[:new_group_name]
        @gitlab_project_id = params[:gitlab_project_id]

        Rails.logger.info "[GITLAB DEBUG] Group ID: #{@gitlab_group_id}, New group name: #{@new_group_name}, Project ID: #{@gitlab_project_id}"

        # Store in project instance if it exists
        if @project
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