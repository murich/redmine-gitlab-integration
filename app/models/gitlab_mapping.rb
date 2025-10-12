class GitlabMapping < ActiveRecord::Base
  belongs_to :project, foreign_key: 'redmine_project_id', class_name: 'Project'

  validates :redmine_project_id, presence: true, uniqueness: true
  validates :mapping_type, inclusion: { in: %w[group project inherited] }, allow_nil: true

  # Find the first GitLab Group in the project or its parent hierarchy
  # Returns: { group_id: Integer, inherited_from: Project } or nil
  def self.find_inherited_group(project)
    return nil unless project

    # First check the project itself
    mapping = find_by(redmine_project_id: project.id)
    return { group_id: mapping.gitlab_group_id, inherited_from: project } if mapping&.gitlab_group_id

    # Then traverse parent hierarchy to find first GitLab Group
    current = project.parent
    while current
      mapping = find_by(redmine_project_id: current.id)
      return { group_id: mapping.gitlab_group_id, inherited_from: current } if mapping&.gitlab_group_id
      current = current.parent
    end
    nil
  end
end
