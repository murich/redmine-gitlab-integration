class GitlabUserMapping < ActiveRecord::Base
  # Mapping between Redmine users and GitLab users
  # This table caches successful user lookups for performance

  validates :redmine_user_id, presence: true, uniqueness: true
  validates :gitlab_user_id, presence: true
  validates :match_method, presence: true, inclusion: { in: %w[casdoor_id username email] }

  # Find GitLab user ID for a Redmine user
  # @param redmine_user_id [Integer] Redmine user ID
  # @return [Integer, nil] GitLab user ID or nil if not found
  def self.find_gitlab_user_id(redmine_user_id)
    mapping = find_by(redmine_user_id: redmine_user_id)
    mapping&.gitlab_user_id
  end

  # Find Redmine user ID for a GitLab user
  # @param gitlab_user_id [Integer] GitLab user ID
  # @return [Integer, nil] Redmine user ID or nil if not found
  def self.find_redmine_user_id(gitlab_user_id)
    mapping = find_by(gitlab_user_id: gitlab_user_id)
    mapping&.redmine_user_id
  end

  # Cache a user mapping
  # @param redmine_user_id [Integer] Redmine user ID
  # @param gitlab_user_id [Integer] GitLab user ID
  # @param gitlab_username [String] GitLab username
  # @param match_method [String] How the match was made ('casdoor_id', 'username', 'email')
  # @return [GitlabUserMapping] The created or updated mapping
  def self.cache_mapping(redmine_user_id, gitlab_user_id, gitlab_username, match_method)
    mapping = find_or_initialize_by(redmine_user_id: redmine_user_id)
    mapping.gitlab_user_id = gitlab_user_id
    mapping.gitlab_username = gitlab_username
    mapping.match_method = match_method
    mapping.last_synced_at = Time.current
    mapping.save!
    mapping
  end

  # Clear cache for a specific Redmine user
  # @param redmine_user_id [Integer] Redmine user ID
  # @return [Boolean] True if mapping was deleted
  def self.clear_cache(redmine_user_id)
    mapping = find_by(redmine_user_id: redmine_user_id)
    mapping&.destroy
  end

  # Clear all cached mappings
  # Use this when GitLab credentials change or for maintenance
  # @return [Integer] Number of mappings deleted
  def self.clear_all_cache
    delete_all
  end

  # Get statistics about cached mappings
  # @return [Hash] Statistics hash with match method counts
  def self.statistics
    {
      total: count,
      by_method: group(:match_method).count,
      recent: where('last_synced_at > ?', 1.day.ago).count
    }
  end
end
