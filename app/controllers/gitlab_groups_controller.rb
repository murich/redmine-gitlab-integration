class GitlabGroupsController < ApplicationController
  before_action :require_login

  def index
    begin
      gitlab_service = RedmineGitlabIntegration::GitlabService.new
      @groups = gitlab_service.list_groups

      respond_to do |format|
        format.json do
          render json: {
            success: true,
            groups: @groups
          }
        end
        format.html do
          render json: {
            success: true,
            groups: @groups
          }
        end
      end
    rescue => e
      Rails.logger.error "[GITLAB GROUPS] Error fetching groups: #{e.message}"

      respond_to do |format|
        format.json do
          render json: {
            success: false,
            error: e.message,
            groups: []
          }, status: :internal_server_error
        end
        format.html do
          render json: {
            success: false,
            error: e.message,
            groups: []
          }, status: :internal_server_error
        end
      end
    end
  end

  # GET /gitlab_groups/:group_id/orphan_projects
  # Returns list of GitLab projects in group that are not mapped to any Redmine project
  def orphan_projects
    group_id = params[:group_id]

    begin
      gitlab_service = RedmineGitlabIntegration::GitlabService.new
      all_projects = gitlab_service.list_group_projects(group_id)

      # Get all mapped GitLab project IDs
      mapped_project_ids = GitlabMapping.where.not(gitlab_project_id: nil).pluck(:gitlab_project_id)

      # Filter out mapped projects - these are "orphans"
      orphan_projects = all_projects.reject { |p| mapped_project_ids.include?(p['id']) }

      Rails.logger.info "[GITLAB GROUPS] Found #{orphan_projects.count} orphan projects in group #{group_id}"

      render json: { success: true, projects: orphan_projects }
    rescue => e
      Rails.logger.error "[GITLAB GROUPS] Error fetching orphan projects: #{e.message}"
      render json: { success: false, error: e.message, projects: [] }, status: :internal_server_error
    end
  end
end
