require_dependency 'projects_controller'

module RedmineGitlabIntegration
  module Patches
    module ProjectsControllerPatch
      def self.included(base)
        base.class_eval do
          before_action :capture_gitlab_params, only: [:create]
          
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
        
        # Store in project instance if it exists
        if @project
          @project.instance_variable_set(:@create_gitlab_project, @create_gitlab_project)
          @project.instance_variable_set(:@create_gitlab_repository, @create_gitlab_repository)
          Rails.logger.info "[GITLAB DEBUG] Stored GitLab params in project instance"
        end
      end
    end
  end
end

# Apply the patch
unless ProjectsController.included_modules.include?(RedmineGitlabIntegration::Patches::ProjectsControllerPatch)
  ProjectsController.send(:prepend, RedmineGitlabIntegration::Patches::ProjectsControllerPatch)
end