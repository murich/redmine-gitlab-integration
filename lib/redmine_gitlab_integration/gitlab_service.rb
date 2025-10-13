module RedmineGitlabIntegration
  class GitlabService
    include HTTParty
    
    def initialize
      # Prefer environment variables over plugin settings for easier deployment
      # Use .presence to convert empty strings to nil for proper fallback
      @gitlab_url = ENV['GITLAB_API_URL'].presence || Setting.plugin_redmine_gitlab_integration['gitlab_url'] || 'http://gitlab_app'
      @gitlab_token = ENV['GITLAB_API_TOKEN'].presence || Setting.plugin_redmine_gitlab_integration['gitlab_token'] || ''
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
        visibility: 'internal'
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
            'repository_storage' => project['repository_storage'],
            'created_at' => project['created_at']
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
    def create_project_in_group(group_id, project_name, description = '', initialize_with_readme = false, is_public = false)
      Rails.logger.info "[GITLAB API] Creating project '#{project_name}' in group #{group_id}"

      endpoint = "#{@gitlab_url}/api/v4/projects"

      params = {
        name: project_name,
        description: description,
        visibility: is_public ? 'public' : 'internal',
        initialize_with_readme: initialize_with_readme,
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

    def create_project(project_name, description = '', initialize_with_readme = false, is_public = false)
      Rails.logger.info "[GITLAB API] Creating project: #{project_name}"

      # GitLab API endpoint for creating projects
      endpoint = "#{@gitlab_url}/api/v4/projects"

      # Project parameters
      params = {
        name: project_name,
        description: description,
        visibility: is_public ? 'public' : 'internal',
        initialize_with_readme: initialize_with_readme,
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
    
    # Find GitLab user ID for a Redmine user
    # Uses three-tier matching: 1) Casdoor ID, 2) Username, 3) Email
    # Results are cached in gitlab_user_mappings table
    # @param redmine_user [User] Redmine user object
    # @return [Integer, nil] GitLab user ID or nil if not found
    def find_gitlab_user_id(redmine_user)
      return nil unless redmine_user

      # 1. Check cache first
      cached_gitlab_id = GitlabUserMapping.find_gitlab_user_id(redmine_user.id)
      if cached_gitlab_id
        Rails.logger.info "[GITLAB USER LOOKUP] Found cached mapping for Redmine user #{redmine_user.login}: GitLab ID #{cached_gitlab_id}"
        return cached_gitlab_id
      end

      # 2. Try Casdoor ID match (most reliable)
      if defined?(OauthIdentity)
        identity = OauthIdentity.find_by(user_id: redmine_user.id, provider: 'casdoor')
        if identity&.uid
          Rails.logger.info "[GITLAB USER LOOKUP] Trying Casdoor ID match for #{redmine_user.login}: #{identity.uid}"
          gitlab_user = find_gitlab_user_by_casdoor_id(identity.uid)
          if gitlab_user
            cache_user_mapping(redmine_user.id, gitlab_user['id'], gitlab_user['username'], 'casdoor_id')
            return gitlab_user['id']
          end
        end
      end

      # 3. Fallback: username match
      Rails.logger.info "[GITLAB USER LOOKUP] Trying username match for #{redmine_user.login}"
      gitlab_user = find_gitlab_user_by_username(redmine_user.login)
      if gitlab_user
        cache_user_mapping(redmine_user.id, gitlab_user['id'], gitlab_user['username'], 'username')
        return gitlab_user['id']
      end

      # 4. Fallback: email match
      if redmine_user.mail.present?
        Rails.logger.info "[GITLAB USER LOOKUP] Trying email match for #{redmine_user.mail}"
        gitlab_user = find_gitlab_user_by_email(redmine_user.mail)
        if gitlab_user
          cache_user_mapping(redmine_user.id, gitlab_user['id'], gitlab_user['username'], 'email')
          return gitlab_user['id']
        end
      end

      Rails.logger.warn "[GITLAB USER LOOKUP] No match found for Redmine user #{redmine_user.login}"
      nil
    end

    # Add or update a group member
    # @param group_id [Integer] GitLab group ID
    # @param gitlab_user_id [Integer] GitLab user ID
    # @param access_level [Integer] Access level (10=Guest, 20=Reporter, 30=Developer, 40=Maintainer, 50=Owner)
    # @return [Hash] Result with success status
    def add_group_member(group_id, gitlab_user_id, access_level)
      Rails.logger.info "[GITLAB MEMBER] Adding user #{gitlab_user_id} to group #{group_id} with access level #{access_level}"

      endpoint = "#{@gitlab_url}/api/v4/groups/#{group_id}/members"
      headers = {
        'Private-Token' => @gitlab_token,
        'Content-Type' => 'application/json'
      }

      params = {
        user_id: gitlab_user_id,
        access_level: access_level
      }

      begin
        response = self.class.post(endpoint,
          body: params.to_json,
          headers: headers,
          timeout: 30
        )

        Rails.logger.info "[GITLAB MEMBER] Response status: #{response.code}"

        if response.success?
          { success: true, message: 'Member added successfully' }
        elsif response.code == 409
          # Member already exists, try updating instead
          Rails.logger.info "[GITLAB MEMBER] Member already exists, updating access level"
          update_group_member(group_id, gitlab_user_id, access_level)
        else
          Rails.logger.error "[GITLAB MEMBER] Failed to add member: #{response.body}"
          { success: false, error: response.body }
        end
      rescue => e
        Rails.logger.error "[GITLAB MEMBER] Error adding member: #{e.message}"
        { success: false, error: e.message }
      end
    end

    # Update group member access level
    # @param group_id [Integer] GitLab group ID
    # @param gitlab_user_id [Integer] GitLab user ID
    # @param access_level [Integer] New access level
    # @return [Hash] Result with success status
    def update_group_member(group_id, gitlab_user_id, access_level)
      Rails.logger.info "[GITLAB MEMBER] Updating user #{gitlab_user_id} in group #{group_id} to access level #{access_level}"

      endpoint = "#{@gitlab_url}/api/v4/groups/#{group_id}/members/#{gitlab_user_id}"
      headers = {
        'Private-Token' => @gitlab_token,
        'Content-Type' => 'application/json'
      }

      params = { access_level: access_level }

      begin
        response = self.class.put(endpoint,
          body: params.to_json,
          headers: headers,
          timeout: 30
        )

        if response.success?
          { success: true, message: 'Member updated successfully' }
        else
          Rails.logger.error "[GITLAB MEMBER] Failed to update member: #{response.body}"
          { success: false, error: response.body }
        end
      rescue => e
        Rails.logger.error "[GITLAB MEMBER] Error updating member: #{e.message}"
        { success: false, error: e.message }
      end
    end

    # Remove a user from a GitLab group
    # @param group_id [Integer] GitLab group ID
    # @param gitlab_user_id [Integer] GitLab user ID
    # @return [Hash] Result with success status
    def remove_group_member(group_id, gitlab_user_id)
      Rails.logger.info "[GITLAB MEMBER] Removing user #{gitlab_user_id} from group #{group_id}"

      endpoint = "#{@gitlab_url}/api/v4/groups/#{group_id}/members/#{gitlab_user_id}"
      headers = { 'Private-Token' => @gitlab_token }

      begin
        response = self.class.delete(endpoint,
          headers: headers,
          timeout: 30
        )

        Rails.logger.info "[GITLAB MEMBER] Remove response status: #{response.code}"

        if response.success? || response.code == 404
          # 404 means user was already not in group - that's okay
          { success: true, message: 'Member removed successfully' }
        else
          Rails.logger.error "[GITLAB MEMBER] Failed to remove member: #{response.body}"
          { success: false, error: response.body }
        end
      rescue => e
        Rails.logger.error "[GITLAB MEMBER] Error removing member: #{e.message}"
        { success: false, error: e.message }
      end
    end

    # Synchronize Redmine project members to GitLab group
    # @param gitlab_group_id [Integer] GitLab group ID
    # @param redmine_project [Project] Redmine project object
    # @return [Hash] Summary of sync operation
    def sync_project_members(gitlab_group_id, redmine_project)
      Rails.logger.info "[GITLAB MEMBER SYNC] Starting member sync for project #{redmine_project.name} to group #{gitlab_group_id}"

      results = {
        total: 0,
        added: 0,
        updated: 0,
        failed: 0,
        errors: []
      }

      redmine_project.members.includes(:user, :roles).each do |member|
        next unless member.user&.active?

        results[:total] += 1
        user = member.user

        # Find GitLab user ID
        gitlab_user_id = find_gitlab_user_id(user)
        unless gitlab_user_id
          results[:failed] += 1
          results[:errors] << "No GitLab user found for Redmine user #{user.login}"
          next
        end

        # Map Redmine roles to GitLab access levels
        access_level = map_role_to_access_level(member.roles)

        # Add member to GitLab group
        result = add_group_member(gitlab_group_id, gitlab_user_id, access_level)
        if result[:success]
          if result[:message].include?('updated')
            results[:updated] += 1
          else
            results[:added] += 1
          end
        else
          results[:failed] += 1
          results[:errors] << "Failed to add #{user.login}: #{result[:error]}"
        end
      end

      Rails.logger.info "[GITLAB MEMBER SYNC] Sync complete: #{results[:added]} added, #{results[:updated]} updated, #{results[:failed]} failed"
      results
    end

    # Add a badge to a GitLab group linking back to Redmine project
    # Badges appear on the group overview page with clickable links
    # @param gitlab_group_id [Integer] GitLab group ID
    # @param redmine_project [Project] Redmine project object
    # @return [Hash] Result with success status
    def add_redmine_badge_to_group(gitlab_group_id, redmine_project)
      Rails.logger.info "[GITLAB BADGE] Adding Redmine link badge to group #{gitlab_group_id}"

      # Get Redmine external URL from environment
      redmine_url = ENV['REDMINE_EXTERNAL_URL'] || 'http://localhost:8087'

      # Build badge parameters
      badge_name = "Redmine Project"
      badge_link = "#{redmine_url}/projects/#{redmine_project.identifier}"
      badge_image = "#{redmine_url}/favicon.ico"

      endpoint = "#{@gitlab_url}/api/v4/groups/#{gitlab_group_id}/badges"
      headers = {
        'Private-Token' => @gitlab_token,
        'Content-Type' => 'application/json'
      }

      params = {
        name: badge_name,
        link_url: badge_link,
        image_url: badge_image
      }

      begin
        response = self.class.post(endpoint,
          body: params.to_json,
          headers: headers,
          timeout: 30
        )

        Rails.logger.info "[GITLAB BADGE] Response status: #{response.code}"

        if response.success?
          Rails.logger.info "[GITLAB BADGE] Badge added successfully: #{badge_link}"
          { success: true, message: 'Badge added successfully', badge_link: badge_link }
        elsif response.code == 400 && response.body.include?('already exists')
          # Badge already exists - that's okay
          Rails.logger.info "[GITLAB BADGE] Badge already exists for group #{gitlab_group_id}"
          { success: true, message: 'Badge already exists', badge_link: badge_link }
        else
          Rails.logger.error "[GITLAB BADGE] Failed to add badge: #{response.body}"
          { success: false, error: response.body }
        end
      rescue => e
        Rails.logger.error "[GITLAB BADGE] Error adding badge: #{e.message}"
        { success: false, error: e.message }
      end
    end

    # Add a badge to a GitLab project linking back to Redmine project
    # @param gitlab_project_id [Integer] GitLab project ID
    # @param redmine_project [Project] Redmine project object
    # @return [Hash] Result with success status
    def add_redmine_badge_to_project(gitlab_project_id, redmine_project)
      Rails.logger.info "[GITLAB BADGE] Adding Redmine link badge to project #{gitlab_project_id}"

      redmine_url = ENV['REDMINE_EXTERNAL_URL'] || 'http://localhost:8087'

      badge_name = "Redmine Project"
      badge_link = "#{redmine_url}/projects/#{redmine_project.identifier}"
      badge_image = "#{redmine_url}/favicon.ico"

      endpoint = "#{@gitlab_url}/api/v4/projects/#{gitlab_project_id}/badges"
      headers = {
        'Private-Token' => @gitlab_token,
        'Content-Type' => 'application/json'
      }

      params = {
        name: badge_name,
        link_url: badge_link,
        image_url: badge_image
      }

      begin
        response = self.class.post(endpoint,
          body: params.to_json,
          headers: headers,
          timeout: 30
        )

        Rails.logger.info "[GITLAB BADGE] Response status: #{response.code}"

        if response.success?
          Rails.logger.info "[GITLAB BADGE] Badge added successfully: #{badge_link}"
          { success: true, message: 'Badge added successfully', badge_link: badge_link }
        elsif response.code == 400 && response.body.include?('already exists')
          Rails.logger.info "[GITLAB BADGE] Badge already exists for project #{gitlab_project_id}"
          { success: true, message: 'Badge already exists', badge_link: badge_link }
        else
          Rails.logger.error "[GITLAB BADGE] Failed to add badge: #{response.body}"
          { success: false, error: response.body }
        end
      rescue => e
        Rails.logger.error "[GITLAB BADGE] Error adding badge: #{e.message}"
        { success: false, error: e.message }
      end
    end

    # Find Redmine badge in a GitLab group by name
    # @param gitlab_group_id [Integer] GitLab group ID
    # @param badge_name [String] Badge name (default: "Redmine Project")
    # @return [Hash, nil] Badge hash with id, or nil if not found
    def find_redmine_badge_in_group(gitlab_group_id, badge_name = "Redmine Project")
      Rails.logger.info "[GITLAB BADGE] Finding badge '#{badge_name}' in group #{gitlab_group_id}"

      endpoint = "#{@gitlab_url}/api/v4/groups/#{gitlab_group_id}/badges"
      headers = { 'Private-Token' => @gitlab_token }

      begin
        response = self.class.get(endpoint,
          headers: headers,
          timeout: 30
        )

        if response.success?
          badges = JSON.parse(response.body)
          badge = badges.find { |b| b['name'] == badge_name }
          if badge
            Rails.logger.info "[GITLAB BADGE] Found badge ID: #{badge['id']}"
            badge
          else
            Rails.logger.info "[GITLAB BADGE] Badge not found in group #{gitlab_group_id}"
            nil
          end
        else
          Rails.logger.error "[GITLAB BADGE] Failed to list badges: #{response.body}"
          nil
        end
      rescue => e
        Rails.logger.error "[GITLAB BADGE] Error finding badge: #{e.message}"
        nil
      end
    end

    # Delete a badge from a GitLab group
    # @param gitlab_group_id [Integer] GitLab group ID
    # @param badge_id [Integer] Badge ID
    # @return [Hash] Result with success status
    def delete_badge_from_group(gitlab_group_id, badge_id)
      Rails.logger.info "[GITLAB BADGE] Deleting badge #{badge_id} from group #{gitlab_group_id}"

      endpoint = "#{@gitlab_url}/api/v4/groups/#{gitlab_group_id}/badges/#{badge_id}"
      headers = { 'Private-Token' => @gitlab_token }

      begin
        response = self.class.delete(endpoint,
          headers: headers,
          timeout: 30
        )

        Rails.logger.info "[GITLAB BADGE] Delete response status: #{response.code}"

        if response.success? || response.code == 404
          # 404 means badge already deleted - that's okay
          Rails.logger.info "[GITLAB BADGE] Badge deleted successfully"
          { success: true, message: 'Badge deleted successfully' }
        else
          Rails.logger.error "[GITLAB BADGE] Failed to delete badge: #{response.body}"
          { success: false, error: response.body }
        end
      rescue => e
        Rails.logger.error "[GITLAB BADGE] Error deleting badge: #{e.message}"
        { success: false, error: e.message }
      end
    end

    # Remove Redmine badge from a GitLab group (find and delete)
    # @param gitlab_group_id [Integer] GitLab group ID
    # @return [Hash] Result with success status
    def remove_redmine_badge_from_group(gitlab_group_id)
      Rails.logger.info "[GITLAB BADGE] Removing Redmine badge from group #{gitlab_group_id}"

      badge = find_redmine_badge_in_group(gitlab_group_id)
      return { success: true, message: 'Badge not found (already removed)' } unless badge

      delete_badge_from_group(gitlab_group_id, badge['id'])
    end

    # Configure Redmine integration on GitLab project
    # @param gitlab_project_id [Integer] GitLab project ID
    # @param redmine_project [Project] Redmine project instance
    # @return [Hash] Result with success status
    def configure_redmine_integration(gitlab_project_id, redmine_project)
      Rails.logger.info "[GITLAB INTEGRATION] Configuring Redmine integration for GitLab project #{gitlab_project_id}"

      redmine_url = ENV['REDMINE_EXTERNAL_URL'].presence || 'http://localhost:8087'
      endpoint = "#{@gitlab_url}/api/v4/projects/#{gitlab_project_id}/integrations/redmine"

      # Prepare integration parameters
      params = {
        project_url: "#{redmine_url}/projects/#{redmine_project.identifier}",
        issues_url: "#{redmine_url}/issues/:id",
        new_issue_url: "#{redmine_url}/projects/#{redmine_project.identifier}/issues/new"
      }

      headers = {
        'Private-Token' => @gitlab_token,
        'Content-Type' => 'application/json'
      }

      Rails.logger.info "[GITLAB INTEGRATION] Request params: #{params.inspect}"

      begin
        response = self.class.put(endpoint,
          headers: headers,
          body: params.to_json,
          timeout: 30
        )

        Rails.logger.info "[GITLAB INTEGRATION] Response status: #{response.code}"
        Rails.logger.info "[GITLAB INTEGRATION] Response body: #{response.body}"

        if response.code.to_i.between?(200, 299)
          Rails.logger.info "[GITLAB INTEGRATION] Successfully configured Redmine integration"
          {
            success: true,
            message: "Redmine integration configured successfully",
            project_url: params[:project_url]
          }
        else
          Rails.logger.error "[GITLAB INTEGRATION] Failed to configure integration: #{response.body}"
          {
            success: false,
            error: "HTTP #{response.code}: #{response.body}",
            message: "Failed to configure Redmine integration"
          }
        end
      rescue => e
        Rails.logger.error "[GITLAB INTEGRATION] Error configuring Redmine integration: #{e.message}"
        Rails.logger.error e.backtrace.first(3).join("\n")
        {
          success: false,
          error: e.message,
          message: "Exception occurred during integration setup"
        }
      end
    end

    # Get current Redmine integration status
    # @param gitlab_project_id [Integer] GitLab project ID
    # @return [Hash, nil] Integration configuration or nil if not found
    def get_redmine_integration(gitlab_project_id)
      Rails.logger.info "[GITLAB INTEGRATION] Getting Redmine integration for GitLab project #{gitlab_project_id}"

      endpoint = "#{@gitlab_url}/api/v4/projects/#{gitlab_project_id}/integrations/redmine"
      headers = { 'Private-Token' => @gitlab_token }

      begin
        response = self.class.get(endpoint,
          headers: headers,
          timeout: 30
        )

        Rails.logger.info "[GITLAB INTEGRATION] Response status: #{response.code}"

        if response.success?
          integration = JSON.parse(response.body)
          Rails.logger.info "[GITLAB INTEGRATION] Integration active: #{integration['active']}"
          integration
        else
          Rails.logger.error "[GITLAB INTEGRATION] Failed to get integration: #{response.body}"
          nil
        end
      rescue => e
        Rails.logger.error "[GITLAB INTEGRATION] Error getting integration: #{e.message}"
        nil
      end
    end

    private

    # Find GitLab user by Casdoor ID (most reliable method)
    def find_gitlab_user_by_casdoor_id(casdoor_id)
      endpoint = "#{@gitlab_url}/api/v4/users"
      headers = { 'Private-Token' => @gitlab_token }

      begin
        response = self.class.get(endpoint,
          headers: headers,
          query: { extern_uid: casdoor_id, provider: 'openid_connect' },
          timeout: 30
        )

        if response.success?
          users = JSON.parse(response.body)
          users.first
        else
          nil
        end
      rescue => e
        Rails.logger.error "[GITLAB USER LOOKUP] Error searching by Casdoor ID: #{e.message}"
        nil
      end
    end

    # Find GitLab user by username
    def find_gitlab_user_by_username(username)
      endpoint = "#{@gitlab_url}/api/v4/users"
      headers = { 'Private-Token' => @gitlab_token }

      begin
        response = self.class.get(endpoint,
          headers: headers,
          query: { username: username },
          timeout: 30
        )

        if response.success?
          users = JSON.parse(response.body)
          users.first
        else
          nil
        end
      rescue => e
        Rails.logger.error "[GITLAB USER LOOKUP] Error searching by username: #{e.message}"
        nil
      end
    end

    # Find GitLab user by email
    def find_gitlab_user_by_email(email)
      endpoint = "#{@gitlab_url}/api/v4/users"
      headers = { 'Private-Token' => @gitlab_token }

      begin
        response = self.class.get(endpoint,
          headers: headers,
          query: { search: email },
          timeout: 30
        )

        if response.success?
          users = JSON.parse(response.body)
          # Exact email match
          users.find { |u| u['email'] == email }
        else
          nil
        end
      rescue => e
        Rails.logger.error "[GITLAB USER LOOKUP] Error searching by email: #{e.message}"
        nil
      end
    end

    # Cache user mapping for performance
    def cache_user_mapping(redmine_user_id, gitlab_user_id, gitlab_username, match_method)
      GitlabUserMapping.cache_mapping(redmine_user_id, gitlab_user_id, gitlab_username, match_method)
      Rails.logger.info "[GITLAB USER LOOKUP] Cached mapping: Redmine #{redmine_user_id} -> GitLab #{gitlab_user_id} (#{match_method})"
    end

    # Map Redmine roles to GitLab access levels
    # Manager (role_id: 3) -> Owner (50)
    # Developer (role_id: 4) -> Developer (30)
    # Reporter (role_id: 5) -> Reporter (20)
    # Default -> Developer (30)
    # @param roles [Array, ActiveRecord::Relation] Array of Role objects or role names
    # @return [Integer] GitLab access level
    def map_role_to_access_level(roles)
      return 30 if roles.empty?

      # Handle both role objects and role name strings
      role_names = if roles.first.is_a?(String)
        roles.map(&:downcase)
      else
        roles.map(&:name).map(&:downcase)
      end

      return 50 if role_names.any? { |name| name.include?('manager') || name.include?('admin') }
      return 30 if role_names.any? { |name| name.include?('developer') }
      return 20 if role_names.any? { |name| name.include?('reporter') }

      # Default to Developer
      30
    end

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