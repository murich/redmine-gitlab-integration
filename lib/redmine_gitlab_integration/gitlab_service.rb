module RedmineGitlabIntegration
  class GitlabService
    include HTTParty
    
    def initialize
      # Prefer environment variables over plugin settings for easier deployment
      @gitlab_url = ENV['GITLAB_API_URL'] || Setting.plugin_redmine_gitlab_integration['gitlab_url'] || 'http://gitlab_app'
      @gitlab_token = ENV['GITLAB_API_TOKEN'] || Setting.plugin_redmine_gitlab_integration['gitlab_token'] || ''
      @gitlab_namespace = Setting.plugin_redmine_gitlab_integration['gitlab_namespace'] || ''

      Rails.logger.info "[GITLAB SERVICE] Initialized with URL: #{@gitlab_url}, Token present: #{@gitlab_token.present?}"
    end
    
    # List all accessible groups
    def list_groups
      Rails.logger.info "[GITLAB API] Fetching groups list"

      endpoint = "#{@gitlab_url}/api/v4/groups"
      headers = { 'Private-Token' => @gitlab_token }

      begin
        response = self.class.get(endpoint,
          headers: headers,
          query: { per_page: 100, all_available: true },
          timeout: 30
        )

        Rails.logger.info "[GITLAB API] Groups response status: #{response.code}"

        if response.success?
          groups = JSON.parse(response.body)
          Rails.logger.info "[GITLAB API] Found #{groups.count} groups"
          groups.map { |g| { 'id' => g['id'], 'name' => g['name'], 'path' => g['path'] } }
        else
          Rails.logger.error "[GITLAB API] Failed to fetch groups: #{response.body}"
          []
        end
      rescue => e
        Rails.logger.error "[GITLAB API] Error fetching groups: #{e.message}"
        []
      end
    end

    # Create a new group
    def create_group(group_name, group_path = nil)
      Rails.logger.info "[GITLAB API] Creating group: #{group_name}"

      group_path ||= group_name.downcase.gsub(/[^a-z0-9\-_]/, '-')
      endpoint = "#{@gitlab_url}/api/v4/groups"

      params = {
        name: group_name,
        path: group_path,
        visibility: 'private'
      }

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

        Rails.logger.info "[GITLAB API] Group creation response status: #{response.code}"

        if response.success?
          result = JSON.parse(response.body)
          {
            success: true,
            group_id: result['id'],
            name: result['name'],
            path: result['path']
          }
        else
          {
            success: false,
            error: response.message,
            details: response.body
          }
        end
      rescue => e
        Rails.logger.error "[GITLAB API] Error creating group: #{e.message}"
        {
          success: false,
          error: e.message
        }
      end
    end

    # Get a single project by ID
    def get_project(project_id)
      Rails.logger.info "[GITLAB API] Fetching project #{project_id}"

      endpoint = "#{@gitlab_url}/api/v4/projects/#{project_id}"
      headers = { 'Private-Token' => @gitlab_token }

      begin
        response = self.class.get(endpoint,
          headers: headers,
          timeout: 30
        )

        Rails.logger.info "[GITLAB API] Project response status: #{response.code}"

        if response.success?
          project = JSON.parse(response.body)
          {
            'id' => project['id'],
            'name' => project['name'],
            'path' => project['path'],
            'path_with_namespace' => project['path_with_namespace'],
            'ssh_url_to_repo' => project['ssh_url_to_repo'],
            'http_url_to_repo' => project['http_url_to_repo'],
            'repository_storage' => project['repository_storage']
          }
        else
          Rails.logger.error "[GITLAB API] Failed to fetch project: #{response.body}"
          nil
        end
      rescue => e
        Rails.logger.error "[GITLAB API] Error fetching project: #{e.message}"
        nil
      end
    end

    # List all projects in a specific group
    def list_group_projects(group_id)
      Rails.logger.info "[GITLAB API] Fetching projects for group #{group_id}"

      endpoint = "#{@gitlab_url}/api/v4/groups/#{group_id}/projects"
      headers = { 'Private-Token' => @gitlab_token }

      begin
        response = self.class.get(endpoint,
          headers: headers,
          query: { per_page: 100, include_subgroups: false },
          timeout: 30
        )

        Rails.logger.info "[GITLAB API] Group projects response status: #{response.code}"

        if response.success?
          projects = JSON.parse(response.body)
          Rails.logger.info "[GITLAB API] Found #{projects.count} projects in group #{group_id}"
          projects.map { |p| {
            'id' => p['id'],
            'name' => p['name'],
            'path' => p['path'],
            'path_with_namespace' => p['path_with_namespace'],
            'ssh_url_to_repo' => p['ssh_url_to_repo'],
            'http_url_to_repo' => p['http_url_to_repo']
          }}
        else
          Rails.logger.error "[GITLAB API] Failed to fetch group projects: #{response.body}"
          []
        end
      rescue => e
        Rails.logger.error "[GITLAB API] Error fetching group projects: #{e.message}"
        []
      end
    end

    # Create a project in a specific group
    def create_project_in_group(group_id, project_name, description = '', create_repo = true, is_public = false)
      Rails.logger.info "[GITLAB API] Creating project '#{project_name}' in group #{group_id}"

      endpoint = "#{@gitlab_url}/api/v4/projects"

      params = {
        name: project_name,
        description: description,
        visibility: is_public ? 'public' : 'private',
        initialize_with_readme: create_repo,
        namespace_id: group_id
      }

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
        Rails.logger.error "[GITLAB API] Error creating project in group: #{e.message}"
        {
          success: false,
          error: e.message
        }
      end
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