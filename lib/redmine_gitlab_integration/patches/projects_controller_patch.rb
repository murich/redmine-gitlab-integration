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
          # Create new GitLab project
          Rails.logger.info "[GITLAB DEBUG] Creating new GitLab project in group #{@gitlab_group_id}"
          result = gitlab_service.create_project_in_group(
            @gitlab_group_id,
            @project.name,
            @project.description || '',
            true,
            @project.is_public?
          )

          if result[:success]
            mapping.gitlab_project_id = result[:project_id]
            set_repository_path_from_gitlab_project(result[:project_id])
            Rails.logger.info "[GITLAB DEBUG] Created new GitLab project: #{result[:project_id]}"
          else
            Rails.logger.error "[GITLAB DEBUG] Failed to create GitLab project: #{result[:error]}"
          end
        else
          # Link to existing GitLab project
          mapping.gitlab_project_id = @gitlab_project_id.to_i
          Rails.logger.info "[GITLAB DEBUG] Linking to existing GitLab project: #{@gitlab_project_id}"

          set_repository_path_from_gitlab_project(@gitlab_project_id.to_i)
        end
      rescue => e
        Rails.logger.error "[GITLAB DEBUG] Error handling GitLab project: #{e.message}"
        Rails.logger.error e.backtrace.first(5).join("\n")
      end

      def set_repository_path(gitlab_http_url)
        return unless @project && gitlab_http_url

        Rails.logger.info "[GITLAB DEBUG] Setting repository path for project #{@project.id}"

        # Convert HTTP URL to shared volume path
        # Example: http://gitlab_app/created-from-gitlab/orphan.git
        # Becomes: /opt/gitlab/git-data/repositories/created-from-gitlab/orphan.git
        repository_path = convert_gitlab_url_to_volume_path(gitlab_http_url)

        Rails.logger.info "[GITLAB DEBUG] Repository path: #{repository_path}"

        # Find or create repository for this project
        repository = @project.repositories.find_or_initialize_by(type: 'Repository::Git')
        repository.url = repository_path
        repository.is_default = true

        if repository.save
          Rails.logger.info "[GITLAB DEBUG] Successfully set repository path: #{repository_path}"
        else
          Rails.logger.error "[GITLAB DEBUG] Failed to set repository: #{repository.errors.full_messages.join(', ')}"
        end
      rescue => e
        Rails.logger.error "[GITLAB DEBUG] Error setting repository path: #{e.message}"
        Rails.logger.error e.backtrace.first(5).join("\n")
      end

      def set_repository_path_from_gitlab_project(gitlab_project_id)
        return unless @project && gitlab_project_id

        Rails.logger.info "[GITLAB DEBUG] Fetching repository disk path for GitLab project #{gitlab_project_id}"

        begin
          # Execute gitlab-rails runner to get the actual disk path (hashed storage)
          # Retry a few times with delay as repository might not be immediately ready after creation
          disk_path = nil
          max_retries = 3

          max_retries.times do |attempt|
            command = "docker exec gitlab_app gitlab-rails runner \"project = Project.find_by(id: #{gitlab_project_id}); puts project.repository.disk_path if project && project.repository\""
            disk_path = `#{command}`.strip

            break if disk_path.present?

            Rails.logger.info "[GITLAB DEBUG] Attempt #{attempt + 1}/#{max_retries}: Repository not ready yet, waiting 2 seconds..."
            sleep 2
          end

          if disk_path.present?
            # GitLab stores at: /var/opt/gitlab/git-data/repositories/repositories/@hashed/...
            # Redmine accesses via shared volume at: /var/opt/gitlab/git-data/repositories/repositories/@hashed/...
            repository_path = "/var/opt/gitlab/git-data/repositories/repositories/#{disk_path}.git"

            Rails.logger.info "[GITLAB DEBUG] GitLab disk path: #{disk_path}"
            Rails.logger.info "[GITLAB DEBUG] Redmine repository path: #{repository_path}"

            # Fix permissions so Redmine can read the repository
            # Extract hash prefix (e.g., "@hashed/4b/22" from "@hashed/4b/22/4b227...")
            hash_parts = disk_path.split('/')
            if hash_parts.length >= 3
              permission_path = "/var/opt/gitlab/git-data/repositories/repositories/#{hash_parts[0..2].join('/')}"
              chmod_cmd = "docker exec gitlab_app chmod -R o+rX #{permission_path}"
              Rails.logger.info "[GITLAB DEBUG] Fixing permissions: #{chmod_cmd}"
              `#{chmod_cmd}`
            end

            # Find or create repository for this project
            repository = @project.repositories.find_or_initialize_by(type: 'Repository::Git')
            repository.url = repository_path
            repository.is_default = true

            if repository.save
              Rails.logger.info "[GITLAB DEBUG] Successfully set repository path: #{repository_path}"

              # Fetch initial changesets
              begin
                repository.fetch_changesets
                Rails.logger.info "[GITLAB DEBUG] Fetched changesets: #{repository.changesets.count}"
              rescue => e
                Rails.logger.error "[GITLAB DEBUG] Error fetching changesets: #{e.message}"
              end
            else
              Rails.logger.error "[GITLAB DEBUG] Failed to set repository: #{repository.errors.full_messages.join(', ')}"
            end
          else
            Rails.logger.error "[GITLAB DEBUG] Could not fetch disk path for GitLab project #{gitlab_project_id}"
          end
        rescue => e
          Rails.logger.error "[GITLAB DEBUG] Error fetching GitLab disk path: #{e.message}"
          Rails.logger.error e.backtrace.first(5).join("\n")
        end
      end

      def convert_gitlab_url_to_volume_path(gitlab_url)
        # Remove protocol and gitlab_app host
        # http://gitlab_app/created-from-gitlab/orphan.git → created-from-gitlab/orphan.git
        path = gitlab_url.sub(%r{https?://[^/]+/}, '')

        # GitLab stores repositories in: /var/opt/gitlab/git-data/repositories/@hashed/...
        # But for newly created projects, the path structure is: /var/opt/gitlab/git-data/repositories/group/project.git
        # Since we're using shared volume mounted at /opt/gitlab/git-data in Redmine
        "/opt/gitlab/git-data/repositories/#{path}"
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