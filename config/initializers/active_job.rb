# ActiveJob configuration for background job processing
# Using async adapter for simple thread-based job execution

Rails.application.configure do
  # Use async adapter (built-in, no gem required)
  # Jobs run in a thread pool within the Rails process
  config.active_job.queue_adapter = :async

  # Log job execution for debugging
  config.active_job.logger = Rails.logger
  config.active_job.verbose_enqueue_logs = true
end
