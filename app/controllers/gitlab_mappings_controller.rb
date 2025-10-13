class GitlabMappingsController < ApplicationController
  before_action :require_admin, except: [:graph_data]
  before_action :check_admin_for_ajax, only: [:graph_data]
  skip_before_action :verify_authenticity_token, only: [:graph_data]

  def index
    # Load all mappings and filter out orphaned ones (where project was deleted)
    @mappings = GitlabMapping.includes(:project).all.select { |m| m.project.present? }
  end

  def graph_data
    render json: {
      nodes: build_nodes,
      connections: build_connections
    }
  end

  def update
    mappings = params[:mappings]
    # TODO: Implement mapping save logic
    render json: { success: true }
  end

  def fetch_parent_group
    project = Project.find_by(id: params[:project_id])
    if project
      inherited = GitlabMapping.find_inherited_group(project)
      render json: {
        group_id: inherited&.dig(:group_id),
        inherited_from: inherited&.dig(:inherited_from)&.name
      }
    else
      render json: { group_id: nil, inherited_from: nil }
    end
  end

  private

  def check_admin_for_ajax
    unless User.current.admin?
      render json: { nodes: [], connections: [], error: 'Admin access required' }, status: :forbidden
    end
  end

  def build_nodes
    nodes = []
    GitlabMapping.includes(:project).each_with_index do |mapping, index|
      # Skip orphaned mappings (project was deleted but mapping still exists)
      next unless mapping.project

      nodes << {
        id: "redmine-#{mapping.redmine_project_id}",
        type: 'redmine',
        label: mapping.project.name,
        x: 100 + (index % 5) * 150,
        y: 100 + (index / 5) * 120
      }

      if mapping.gitlab_group_id
        nodes << {
          id: "gitlab-group-#{mapping.gitlab_group_id}",
          type: 'gitlab-group',
          label: "Group #{mapping.gitlab_group_id}",
          x: 100 + (index % 5) * 150 + 200,
          y: 100 + (index / 5) * 120
        }
      end

      if mapping.gitlab_project_id
        nodes << {
          id: "gitlab-repo-#{mapping.gitlab_project_id}",
          type: 'gitlab-repo',
          label: "Repo #{mapping.gitlab_project_id}",
          x: 100 + (index % 5) * 150 + 400,
          y: 100 + (index / 5) * 120
        }
      end
    end
    nodes.uniq { |n| n[:id] }
  end

  def build_connections
    connections = []
    GitlabMapping.includes(:project).each do |mapping|
      # Skip orphaned mappings (project was deleted but mapping still exists)
      next unless mapping.project

      if mapping.gitlab_group_id
        connections << {
          source: "redmine-#{mapping.redmine_project_id}",
          target: "gitlab-group-#{mapping.gitlab_group_id}"
        }
      end

      if mapping.gitlab_project_id && mapping.gitlab_group_id
        connections << {
          source: "gitlab-group-#{mapping.gitlab_group_id}",
          target: "gitlab-repo-#{mapping.gitlab_project_id}"
        }
      end
    end
    connections
  end
end
