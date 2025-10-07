# GitLab Integration Configuration

## Overview
This plugin automatically creates GitLab projects and repositories when creating Redmine projects.
It integrates with the GitLab instance running in your docker stack at `http://gitlab_app`.

## Setup Instructions

### 1. GitLab Token Setup
Generate a personal access token in GitLab with appropriate permissions:

```bash
# Access GitLab (default: http://localhost:8084)
# Login as root or create admin user
# Go to User Settings → Access Tokens
# Create token with these scopes:
#   - api (full API access)
#   - read_user
#   - read_repository
#   - write_repository
```

### 2. Plugin Configuration
Configure the plugin in Redmine:

```
# Navigate to: Redmine → Administration → Plugins → GitLab Integration → Configure

GitLab URL: http://gitlab_app
GitLab Token: [your generated token from step 1]
GitLab Namespace: [optional - leave empty for user's namespace]
```

### 3. Project Module Activation
For each project that should integrate with GitLab:

```
# Navigate to: Project → Settings → Modules
# Enable: "GitLab Integration" module
```

### 4. Automatic Integration
Once configured, new Redmine projects will:
- Automatically create corresponding GitLab projects
- Set up Git repositories accessible in Redmine
- Link repository commits to Redmine issues

## Volume Configuration

The plugin expects GitLab repositories to be accessible at:
```
/var/opt/gitlab/git-data/repositories
```

This is mapped via the shared volume in docker-compose.yml:
```yaml
volumes:
  - shared_git_repos:/var/opt/gitlab/git-data/repositories
```

## Environment Variables (Alternative)

Instead of web configuration, you can set environment variables:

```yaml
# Add to redmine6_app environment in docker-compose.yml
GITLAB_INTEGRATION_URL: http://gitlab_app
GITLAB_INTEGRATION_TOKEN: your-gitlab-token-here
GITLAB_INTEGRATION_NAMESPACE: your-namespace  # optional
```

## Testing Integration

1. **Create Test Project**:
   ```
   # In Redmine: Projects → New Project
   # Enable GitLab Integration module
   # Check GitLab for automatically created project
   ```

2. **Verify Repository Access**:
   ```
   # In Redmine: Project → Repository tab
   # Should show GitLab repository contents
   # Test commit linking with issue IDs
   ```

3. **Debug Logs**:
   ```bash
   # Check Redmine logs for GitLab integration activity
   docker logs redmine6_app | grep "GITLAB DEBUG"
   ```

## Troubleshooting

### Common Issues:

1. **"GitLab project creation failed"**
   - Verify GitLab token has API access
   - Check GitLab service is accessible from Redmine container
   - Ensure GitLab namespace exists (if specified)

2. **"Repository not accessible"**
   - Verify shared volume mount is working
   - Check GitLab repository storage path
   - Ensure Redmine has read access to repository files

3. **"Plugin not loading"**
   - Restart Redmine container after plugin installation
   - Check for Ruby compatibility issues in logs
   - Verify all plugin dependencies are installed

### Debug Commands:

```bash
# Test GitLab API connectivity from Redmine container
docker exec redmine6_app curl -H "Private-Token: YOUR_TOKEN" http://gitlab_app/api/v4/projects

# Check shared volume mount
docker exec redmine6_app ls -la /var/opt/gitlab/git-data/repositories

# View plugin logs
docker logs redmine6_app | grep -i gitlab
```
