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
end
