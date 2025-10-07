require_dependency 'project'

module RedmineGitlabIntegration
  module Patches
    module ProjectPatch
      def self.included(base)
        base.class_eval do
          after_create :create_gitlab_project_and_repository_with_debug
          
          Rails.logger.info "[GITLAB DEBUG] Enhanced ProjectPatch loaded and applied to Project model"
        end
        Rails.logger.info "[GITLAB DEBUG] ProjectPatch included in Project model"
      end

      private

      def create_gitlab_project_and_repository_with_debug
        begin
          Rails.logger.info "[GITLAB DEBUG] === PROJECT CREATION CALLBACK START ==="
          Rails.logger.info "[GITLAB DEBUG] Project: #{self.name} (ID: #{self.id}, Identifier: #{self.identifier})"
          
          # Log creation context
          begin
            stack_trace = caller[0..2].join("\n")
            Rails.logger.info "[GITLAB DEBUG] Created by: #{User.current.try(:login) || 'Unknown'}"
            Rails.logger.info "[GITLAB DEBUG] Creation method: #{get_creation_method} - Stack: #{stack_trace}"
          rescue => e
            Rails.logger.info "[GITLAB DEBUG] Error getting creation context: #{e.message}"
          end

          # Get GitLab creation preferences
          gitlab_params = get_gitlab_creation_params
          create_project = gitlab_params[:create_project]
          create_repository = gitlab_params[:create_repository]

          Rails.logger.info "[GITLAB DEBUG] create_gitlab_project = #{create_project.inspect}"
          Rails.logger.info "[GITLAB DEBUG] create_gitlab_repository = #{create_repository.inspect}"

          # Get controller parameters if available
          begin
            controller_gitlab_params = get_controller_gitlab_params
            Rails.logger.info "[GITLAB DEBUG] Controller gitlab_project = #{controller_gitlab_params[:gitlab_project].inspect}"
            Rails.logger.info "[GITLAB DEBUG] Controller gitlab_repository = #{controller_gitlab_params[:gitlab_repository].inspect}"
          rescue => e
            Rails.logger.info "[GITLAB DEBUG] Error accessing request parameters: #{e.message}"
            Rails.logger.info "[GITLAB DEBUG] Backtrace: #{e.backtrace.first(3).join("\n")}"
            controller_gitlab_params = {}
          end

          # Determine final values
          effective_create_project = create_project || controller_gitlab_params[:gitlab_project] == '1'
          effective_create_repository = create_repository || controller_gitlab_params[:gitlab_repository] == '1'

          Rails.logger.info "[GITLAB DEBUG] Effective create_project = #{effective_create_project.inspect}"
          Rails.logger.info "[GITLAB DEBUG] Effective create_repository = #{effective_create_repository.inspect}"

          # Log project attributes
          Rails.logger.info "[GITLAB DEBUG] Project attributes: #{self.attributes.inspect}"
          
          # Log instance variables
          Rails.logger.info "[GITLAB DEBUG] Instance variables:"
          self.instance_variables.each do |var|
            begin
              value = self.instance_variable_get(var)
              Rails.logger.info "[GITLAB DEBUG]   #{var} = #{value.inspect}" unless var.to_s.include?('password')
            rescue => e
              Rails.logger.info "[GITLAB DEBUG]   #{var} = <error: #{e.message}>"
            end
          end

          # Only proceed if GitLab creation is requested
          unless effective_create_project || effective_create_repository
            Rails.logger.info "[GITLAB DEBUG] GitLab creation not requested, skipping"
            return
          end

          Rails.logger.info "[GITLAB DEBUG] Proceeding with GitLab integration..."

          # Initialize GitLab API client
          gitlab_client = get_gitlab_client
          unless gitlab_client
            Rails.logger.error "[GITLAB DEBUG] Failed to initialize GitLab client"
            return
          end

          gitlab_project = nil

          # Create GitLab project if requested
          if effective_create_project
            Rails.logger.info "[GITLAB DEBUG] Creating GitLab project..."
            gitlab_project = create_gitlab_project_via_api(gitlab_client)
          end

          # Create GitLab repository if requested
          if effective_create_repository
            Rails.logger.info "[GITLAB DEBUG] Creating GitLab repository..."
            unless gitlab_project
              # If we didn't create a project above, try to find existing one
              gitlab_project = find_existing_gitlab_project(gitlab_client)
            end
            
            if gitlab_project
              create_gitlab_repository_in_redmine(gitlab_project)
            else
              Rails.logger.error "[GITLAB DEBUG] No GitLab project available for repository creation"
            end
          end

          Rails.logger.info "[GITLAB DEBUG] === PROJECT CREATION CALLBACK END ==="

        rescue => e
          Rails.logger.error "[GITLAB DEBUG] Error in create_gitlab_project_and_repository_with_debug: #{e.message}"
          Rails.logger.error "[GITLAB DEBUG] Backtrace: #{e.backtrace.first(5).join("\n")}"
        end
      end

      def get_creation_method
        return "Web Form" if defined?(params) && params.present?
        return "Rails Console" if caller.any? { |line| line.include?('console') }
        return "API" if caller.any? { |line| line.include?('api') }
        "Unknown"
      end

      def get_gitlab_creation_params
        # Try to get from instance variables first (set by controller)
        create_project = instance_variable_get(:@create_gitlab_project)
        create_repository = instance_variable_get(:@create_gitlab_repository)
        
        {
          create_project: create_project,
          create_repository: create_repository
        }
      end

      def get_controller_gitlab_params
        # Try to access current request parameters
        if defined?(ActionDispatch::Request) && ActionDispatch::Request.current
          request = ActionDispatch::Request.current
          {
            gitlab_project: request.params['create_gitlab_project'],
            gitlab_repository: request.params['create_gitlab_repository']
          }
        else
          {}
        end
      end

      def get_gitlab_client
        begin
          require 'net/http'
          require 'json'
          require 'uri'

          gitlab_url = 'http://gitlab_app'  # Internal Docker network URL
          gitlab_token = get_gitlab_root_token

          Rails.logger.info "[GITLAB DEBUG] Connecting to GitLab at: #{gitlab_url}"
          Rails.logger.info "[GITLAB DEBUG] Using token: #{gitlab_token ? 'Present' : 'Missing'}"

          return { url: gitlab_url, token: gitlab_token }
        rescue => e
          Rails.logger.error "[GITLAB DEBUG] Error initializing GitLab client: #{e.message}"
          return nil
        end
      end

      def get_gitlab_root_token
        # For now, use a hardcoded token - in production this should be from environment or secure storage
        # This token needs to be generated after GitLab setup
        'glpat-your-gitlab-root-token-here'
      end

      def create_gitlab_project_via_api(client)
        begin
          uri = URI("#{client[:url]}/api/v4/projects")
          http = Net::HTTP.new(uri.host, uri.port)
          http.read_timeout = 30
          http.open_timeout = 10

          request = Net::HTTP::Post.new(uri)
          request['Private-Token'] = client[:token]
          request['Content-Type'] = 'application/json'

          project_data = {
            name: self.name,
            path: self.identifier,
            description: self.description.to_s,
            visibility: 'private',
            initialize_with_readme: true
          }

          request.body = project_data.to_json
          Rails.logger.info "[GITLAB DEBUG] Creating GitLab project with data: #{project_data.inspect}"

          response = http.request(request)
          Rails.logger.info "[GITLAB DEBUG] GitLab API response code: #{response.code}"
          Rails.logger.info "[GITLAB DEBUG] GitLab API response body: #{response.body}"

          if response.code.to_i.between?(200, 299)
            gitlab_project = JSON.parse(response.body)
            Rails.logger.info "[GITLAB DEBUG] GitLab project created successfully: #{gitlab_project['web_url']}"
            return gitlab_project
          else
            Rails.logger.error "[GITLAB DEBUG] Failed to create GitLab project: #{response.body}"
            return nil
          end

        rescue => e
          Rails.logger.error "[GITLAB DEBUG] Error creating GitLab project: #{e.message}"
          Rails.logger.error "[GITLAB DEBUG] Backtrace: #{e.backtrace.first(3).join("\n")}"
          return nil
        end
      end

      def find_existing_gitlab_project(client)
        begin
          uri = URI("#{client[:url]}/api/v4/projects/#{ERB::Util.url_encode(self.identifier)}")
          http = Net::HTTP.new(uri.host, uri.port)

          request = Net::HTTP::Get.new(uri)
          request['Private-Token'] = client[:token]

          response = http.request(request)

          if response.code.to_i == 200
            return JSON.parse(response.body)
          else
            Rails.logger.info "[GITLAB DEBUG] GitLab project not found: #{response.code}"
            return nil
          end
        rescue => e
          Rails.logger.error "[GITLAB DEBUG] Error finding GitLab project: #{e.message}"
          return nil
        end
      end

      def create_gitlab_repository_in_redmine(gitlab_project)
        begin
          Rails.logger.info "[GITLAB DEBUG] Adding GitLab repository to Redmine project..."

          # Calculate local repository path for GitLab hashed storage
          local_repo_path = get_local_repository_path(gitlab_project)
          Rails.logger.info "[GITLAB DEBUG] Calculated local repository path: #{local_repo_path}"

          # Create repository in Redmine
          repository = Repository::Git.new(
            project: self,
            url: local_repo_path,
            identifier: 'gitlab-main',
            is_default: true
          )

          if repository.save
            Rails.logger.info "[GITLAB DEBUG] Repository added to Redmine successfully"
            return repository
          else
            Rails.logger.error "[GITLAB DEBUG] Failed to save repository: #{repository.errors.full_messages.join(', ')}"
            return nil
          end

        rescue => e
          Rails.logger.error "[GITLAB DEBUG] Error creating repository in Redmine: #{e.message}"
          Rails.logger.error "[GITLAB DEBUG] Backtrace: #{e.backtrace.first(3).join("\n")}"
          return nil
        end
      end

      def get_local_repository_path(gitlab_project)
        begin
          # GitLab uses hashed storage by default
          project_id = gitlab_project['id']
          hash = Digest::SHA256.hexdigest(project_id.to_s)
          hashed_path = File.join(hash[0..1], hash[2..3], hash)
          
          # Primary path in GitLab hashed storage
          local_path = "/var/opt/gitlab/git-data/repositories/@hashed/#{hashed_path}.git"
          
          Rails.logger.info "[GITLAB DEBUG] GitLab project ID: #{project_id}"
          Rails.logger.info "[GITLAB DEBUG] Calculated hash: #{hash}"
          Rails.logger.info "[GITLAB DEBUG] Hashed path: #{hashed_path}"
          Rails.logger.info "[GITLAB DEBUG] Full local path: #{local_path}"
          
          # Fallback to project path if hashed storage fails
          fallback_path = "/var/opt/gitlab/git-data/repositories/#{gitlab_project['path_with_namespace']}.git"
          Rails.logger.info "[GITLAB DEBUG] Fallback path: #{fallback_path}"
          
          return local_path
          
        rescue => e
          Rails.logger.error "[GITLAB DEBUG] Error calculating repository path: #{e.message}"
          # Return a basic fallback path
          return "/var/opt/gitlab/git-data/repositories/#{self.identifier}.git"
        end
      end
    end
  end
end

# Apply the patch
unless Project.included_modules.include?(RedmineGitlabIntegration::Patches::ProjectPatch)
  Project.send(:include, RedmineGitlabIntegration::Patches::ProjectPatch)
end