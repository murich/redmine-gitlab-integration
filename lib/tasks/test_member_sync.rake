namespace :gitlab do
  desc "Test member sync functionality"
  task :test_sync => :environment do
    puts "=" * 80
    puts "TESTING MEMBER SYNC"
    puts "=" * 80

    # Check if patch is applied
    puts "\n1. Checking if Member patch is applied..."
    if Member.included_modules.include?(RedmineGitlabIntegration::Patches::MemberPatch)
      puts "   ✓ Member patch is applied"
    else
      puts "   ✗ Member patch is NOT applied"
      puts "   Applying patch now..."
      require_dependency File.expand_path('../../../lib/redmine_gitlab_integration/patches/member_patch', __FILE__)
    end

    # Check GitlabMapping
    puts "\n2. Checking GitlabMapping..."
    mapping = GitlabMapping.find_by(redmine_project_id: 1)
    if mapping
      puts "   ✓ GitlabMapping exists: Project 1 → Group #{mapping.gitlab_group_id}"
    else
      puts "   ✗ GitlabMapping does NOT exist for Project 1"
      puts "   Creating mapping..."
      mapping = GitlabMapping.create!(
        redmine_project_id: 1,
        gitlab_group_id: 8,
        mapping_type: 'group'
      )
      puts "   ✓ Created mapping: Project 1 → Group 8"
    end

    # Check testdev1
    puts "\n3. Checking testdev1 user..."
    user = User.find_by(login: 'testdev1')
    if user
      puts "   ✓ testdev1 exists (ID: #{user.id})"
    else
      puts "   ✗ testdev1 does NOT exist"
      exit 1
    end

    # Check Member record
    puts "\n4. Checking Member record..."
    member = Member.find_by(user_id: user.id, project_id: 1)
    if member
      puts "   ✓ Member record exists (ID: #{member.id})"
      puts "     Roles: #{member.roles.map(&:name).join(', ')}"
    else
      puts "   ✗ Member record does NOT exist"
      exit 1
    end

    # Manually trigger sync
    puts "\n5. Manually triggering sync..."
    begin
      gitlab_group_id = mapping.gitlab_group_id
      access_level = 30 # Developer

      puts "   Calling SyncMemberJob.new.perform('add', #{gitlab_group_id}, #{user.id}, #{access_level})"
      SyncMemberJob.new.perform('add', gitlab_group_id, user.id, access_level)
      puts "   ✓ Sync completed successfully"
    rescue => e
      puts "   ✗ Sync failed: #{e.message}"
      puts "   Backtrace:"
      e.backtrace.first(5).each { |line| puts "     #{line}" }
      exit 1
    end

    # Verify in GitLab
    puts "\n6. Verifying in GitLab..."
    require 'net/http'
    require 'json'

    uri = URI("http://localhost:8084/api/v4/groups/8/members")
    request = Net::HTTP::Get.new(uri)
    request['PRIVATE-TOKEN'] = 'glpat-oglPLqqRLX5hRxZ5Nizogm86MQp1OjEH.01.0w0g897qf'

    response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
    members = JSON.parse(response.body)

    testdev_member = members.find { |m| m['username'] == 'testdev1' }
    if testdev_member
      puts "   ✓ testdev1 found in GitLab Group 8"
      puts "     Access Level: #{testdev_member['access_level']}"
    else
      puts "   ✗ testdev1 NOT found in GitLab Group 8"
      puts "   Current members: #{members.map { |m| m['username'] }.join(', ')}"
    end

    puts "\n" + "=" * 80
    puts "TEST COMPLETE"
    puts "=" * 80
  end
end
