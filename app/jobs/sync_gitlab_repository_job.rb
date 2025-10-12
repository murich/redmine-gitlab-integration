# frozen_string_literal: true

class SyncGitlabRepositoryJob < ApplicationJob
  queue_as :default

  # Maximum number of retry attempts
  MAX_ATTEMPTS = 10

  # Exponential backoff delays (in seconds)
  RETRY_DELAYS = [0, 5, 10, 20, 40, 80, 80, 80, 80, 80].freeze

  def perform(redmine_project_id, gitlab_project_id, attempt = 1, created_after_timestamp = nil)
    # Use the timestamp when the mapping was created to ensure we only link repos created AFTER that
    created_after_timestamp ||= Time.now.to_i

    Rails.logger.info "[SYNC JOB] Attempt #{attempt}/#{MAX_ATTEMPTS} - Syncing GitLab repository for Redmine project #{redmine_project_id}, GitLab project #{gitlab_project_id}"
    Rails.logger.info "[SYNC JOB] Looking for repos created after #{Time.at(created_after_timestamp)}"

    # Find the Redmine project
    project = Project.find_by(id: redmine_project_id)
    unless project
      Rails.logger.error "[SYNC JOB] Redmine project #{redmine_project_id} not found"
      return
    end

    # Try to fetch disk path from GitLab
    disk_path = fetch_gitlab_disk_path(gitlab_project_id, created_after_timestamp)

    if disk_path.present?
      # Success! Create repository entry
      create_repository(project, disk_path, gitlab_project_id)
      Rails.logger.info "[SYNC JOB] Successfully synced repository for project #{project.name}"
    elsif attempt < MAX_ATTEMPTS
      # Repository not ready yet, retry with delay
      delay = RETRY_DELAYS[attempt]
      Rails.logger.info "[SYNC JOB] Repository not ready yet, retrying in #{delay} seconds (attempt #{attempt + 1}/#{MAX_ATTEMPTS})"

      # Schedule next attempt - pass along the created_after_timestamp
      SyncGitlabRepositoryJob.set(wait: delay.seconds).perform_later(redmine_project_id, gitlab_project_id, attempt + 1, created_after_timestamp)
    else
      # Max attempts reached, give up
      Rails.logger.error "[SYNC JOB] Failed to sync GitLab repository after #{MAX_ATTEMPTS} attempts for Redmine project #{redmine_project_id}, GitLab project #{gitlab_project_id}"
    end
  rescue => e
    Rails.logger.error "[SYNC JOB] Error in sync job: #{e.message}"
    Rails.logger.error e.backtrace.first(5).join("\n")
  end

  private

  def fetch_gitlab_disk_path(gitlab_project_id, created_after_timestamp)
    # Strategy: Find repos created AFTER the Redmine project was saved
    # This ensures we link the correct repo even if multiple are created simultaneously
    base_path = "/var/opt/gitlab/git-data/repositories/repositories/@hashed"
    created_after = Time.at(created_after_timestamp)

    # Get all repositories that are already mapped to OTHER Redmine projects
    # This prevents linking the wrong repo if multiple were created recently
    mapped_repos = Repository.where(type: 'Repository::Git')
                            .where("url LIKE ?", "#{base_path}/%")
                            .pluck(:url)
                            .map { |url| url.sub("#{base_path}/", '@hashed/').sub('.git', '') }

    Rails.logger.info "[SYNC JOB] Found #{mapped_repos.count} already-mapped repositories to exclude"

    # Get all .git directories in hashed storage (exclude wikis and design repos)
    git_dirs = Dir.glob("#{base_path}/*/*/*.git").reject do |d|
      d.include?('.wiki.git') || d.include?('.design.git')
    end

    Rails.logger.info "[SYNC JOB] Scanning #{git_dirs.count} total repositories in hashed storage"

    # Filter to repos created AFTER our timestamp and sort by oldest first
    # We want the FIRST repo created after our timestamp (not newest)
    matching_repos = git_dirs.select do |d|
      File.directory?(d) && File.mtime(d) > created_after
    end.sort_by { |d| File.mtime(d).to_i } # Oldest first (earliest after our timestamp)

    Rails.logger.info "[SYNC JOB] Found #{matching_repos.count} repositories created after #{created_after}"

    # Try each repo in order (oldest first) that hasn't been mapped yet
    matching_repos.each do |git_dir|
      # Extract the disk_path
      next unless git_dir =~ %r{@hashed/.+\.git$}

      disk_path = git_dir.sub("#{base_path}/", '@hashed/').sub('.git', '')
      repo_created_at = File.mtime(git_dir)

      # Skip if this repo is already mapped to another project
      if mapped_repos.include?(disk_path)
        Rails.logger.info "[SYNC JOB] Skipping already-mapped repository: #{disk_path}"
        next
      end

      # Verify it's a valid git repository with proper initialization
      if File.exist?("#{git_dir}/HEAD") && File.exist?("#{git_dir}/config")
        has_refs = Dir.exist?("#{git_dir}/refs/heads")
        Rails.logger.info "[SYNC JOB] Found unmapped candidate: #{disk_path} (created #{repo_created_at}, #{(repo_created_at - created_after).round(2)}s after trigger, has_refs: #{has_refs})"

        # Return the first (oldest) unmapped repo created after our timestamp
        return disk_path
      end
    end

    Rails.logger.warn "[SYNC JOB] No valid unmapped repository found created after #{created_after}"
    nil
  rescue => e
    Rails.logger.error "[SYNC JOB] Error fetching disk path: #{e.message}"
    Rails.logger.error e.backtrace.first(3).join("\n")
    nil
  end

  def create_repository(project, disk_path, gitlab_project_id)
    # GitLab stores at: /var/opt/gitlab/git-data/repositories/repositories/@hashed/...
    # Redmine accesses via shared volume at: /var/opt/gitlab/git-data/repositories/repositories/@hashed/...
    repository_path = "/var/opt/gitlab/git-data/repositories/repositories/#{disk_path}.git"

    Rails.logger.info "[SYNC JOB] GitLab disk path: #{disk_path}"
    Rails.logger.info "[SYNC JOB] Redmine repository path: #{repository_path}"

    # Note: Permissions are set by GitLab init script on hashed storage directories
    # No need to fix permissions at runtime

    # Find or create repository for this project
    repository = project.repositories.find_or_initialize_by(type: 'Repository::Git')
    repository.url = repository_path
    repository.is_default = true

    if repository.save
      Rails.logger.info "[SYNC JOB] Successfully set repository path: #{repository_path}"

      # Fetch initial changesets
      begin
        repository.fetch_changesets
        Rails.logger.info "[SYNC JOB] Fetched changesets: #{repository.changesets.count}"
      rescue => e
        Rails.logger.error "[SYNC JOB] Error fetching changesets: #{e.message}"
      end
    else
      Rails.logger.error "[SYNC JOB] Failed to save repository: #{repository.errors.full_messages.join(', ')}"
    end
  rescue => e
    Rails.logger.error "[SYNC JOB] Error creating repository: #{e.message}"
    Rails.logger.error e.backtrace.first(5).join("\n")
  end
end
