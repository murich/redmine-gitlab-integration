module RedmineGitlabIntegration
  class Hooks < Redmine::Hook::ViewListener
    # Add GitLab integration checkboxes to project form
    def view_projects_form(context = {})
      context[:controller].send(:render_to_string, {
        :partial => 'hooks/gitlab_project_form',
        :locals => context
      })
    end
    
    # Add GitLab link to project overview
    def view_projects_show_left(context = {})
      project = context[:project]
      
      if project.custom_field_values.any? { |cf| cf.custom_field.name == 'GitLab Project ID' && cf.value.present? }
        gitlab_url = Setting.plugin_redmine_gitlab_integration['gitlab_url'] || 'http://localhost:8086'
        gitlab_project_id = project.custom_field_values.find { |cf| cf.custom_field.name == 'GitLab Project ID' }.value
        
        content_tag(:div, class: 'gitlab-link box') do
          content_tag(:h3, 'GitLab Integration') +
          content_tag(:p) do
            link_to('View in GitLab', "#{gitlab_url}/projects/#{gitlab_project_id}", 
                   target: '_blank', class: 'icon icon-external')
          end
        end
      end
    end
  end
end