module RedmineGitlabIntegration
  class GitlabService
    include HTTParty
    
    def initialize
      @gitlab_url = Setting.plugin_redmine_gitlab_integration['gitlab_url'] || 'http://gitlab_app'
      @gitlab_token = Setting.plugin_redmine_gitlab_integration['gitlab_token'] || ''
      @gitlab_namespace = Setting.plugin_redmine_gitlab_integration['gitlab_namespace'] || ''
    end
    
    def create_project(project_name, description = '', create_repo = true, is_public = false)
      Rails.logger.info "[GITLAB API] Creating project: #{project_name}"
      
      # GitLab API endpoint for creating projects
      endpoint = "#{@gitlab_url}/api/v4/projects"
      
      # Project parameters
      params = {
        name: project_name,
        description: description,
        visibility: is_public ? 'public' : 'private',
        initialize_with_readme: create_repo,
        namespace_id: get_namespace_id
      }
      
      # Headers with authentication
      headers = {
        'Private-Token' => @gitlab_token,
        'Content-Type' => 'application/json'
      }
      
      begin
        response = self.class.post(endpoint, 
          body: params.to_json,
          headers: headers,
          timeout: 30
        )
        
        Rails.logger.info "[GITLAB API] Response status: #{response.code}"
        Rails.logger.info "[GITLAB API] Response body: #{response.body}"
        
        if response.success?
          result = JSON.parse(response.body)
          {
            success: true,
            project_id: result['id'],
            web_url: result['web_url'],
            ssh_url: result['ssh_url_to_repo'],
            http_url: result['http_url_to_repo']
          }
        else
          {
            success: false,
            error: response.message,
            details: response.body
          }
        end
      rescue => e
        Rails.logger.error "[GITLAB API] Error creating project: #{e.message}"
        {
          success: false,
          error: e.message
        }
      end
    end
    
    private
    
    def get_namespace_id
      # If namespace is specified, fetch its ID
      return nil if @gitlab_namespace.blank?
      
      begin
        response = self.class.get("#{@gitlab_url}/api/v4/namespaces", 
          headers: { 'Private-Token' => @gitlab_token }
        )
        
        if response.success?
          namespaces = JSON.parse(response.body)
          namespace = namespaces.find { |ns| ns['path'] == @gitlab_namespace }
          namespace ? namespace['id'] : nil
        else
          nil
        end
      rescue => e
        Rails.logger.error "[GITLAB API] Error fetching namespace: #{e.message}"
        nil
      end
    end
  end
end