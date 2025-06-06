# frozen_string_literal: true

require "active_job"
require "active_job/queue_adapters"

require_relative "good_job/version"
require_relative "good_job/engine"

require_relative "good_job/adapter"
require_relative "good_job/adapter/inline_buffer"
require_relative "active_job/queue_adapters/good_job_adapter"
require_relative "good_job/active_job_extensions/batches"
require_relative "good_job/active_job_extensions/concurrency"
require_relative "good_job/interrupt_error"
require_relative "good_job/active_job_extensions/interrupt_errors"
require_relative "good_job/active_job_extensions/labels"
require_relative "good_job/active_job_extensions/notify_options"

require_relative "good_job/overridable_connection"
require_relative "good_job/bulk"
require_relative "good_job/callable"
require_relative "good_job/capsule"
require_relative "good_job/capsule_tracker"
require_relative "good_job/cleanup_tracker"
require_relative "good_job/cli"
require_relative "good_job/configuration"
require_relative "good_job/cron_manager"
require_relative "good_job/current_thread"
require_relative "good_job/daemon"
require_relative "good_job/dependencies"
require_relative "good_job/job_performer"
require_relative "good_job/job_performer/metrics"
require_relative "good_job/log_subscriber"
require_relative "good_job/multi_scheduler"
require_relative "good_job/notifier"
require_relative "good_job/poller"
require_relative "good_job/probe_server"
require_relative "good_job/probe_server/healthcheck_middleware"
require_relative "good_job/probe_server/not_found_app"
require_relative "good_job/probe_server/simple_handler"
require_relative "good_job/probe_server/webrick_handler"
require_relative "good_job/scheduler"
require_relative "good_job/shared_executor"
require_relative "good_job/systemd_service"
require_relative "good_job/thread_status"

# GoodJob is a multithreaded, Postgres-based, ActiveJob backend for Ruby on Rails.
#
# +GoodJob+ is the top-level namespace and exposes configuration attributes.
module GoodJob
  include GoodJob::Dependencies
  include GoodJob::ThreadStatus

  # Default, null, blank value placeholder.
  NONE = Module.new.freeze

  # Default logger for GoodJob; overridden by Rails.logger in Railtie.
  DEFAULT_LOGGER = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new($stdout))

  # @!attribute [rw] active_record_parent_class
  #   @!scope class
  #   The ActiveRecord parent class inherited by +GoodJob::Job+ (default: +ActiveRecord::Base+).
  #   Use this when using multiple databases or other custom ActiveRecord configuration.
  #   @return [ActiveRecord::Base]
  #   @example Change the base class:
  #     GoodJob.active_record_parent_class = "CustomApplicationRecord"
  mattr_accessor :active_record_parent_class, default: nil

  # @!attribute [rw] logger
  #   @!scope class
  #   The logger used by GoodJob (default: +Rails.logger+).
  #   Use this to redirect logs to a special location or file.
  #   @return [Logger, nil]
  #   @example Output GoodJob logs to a file:
  #     GoodJob.logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new("log/my_logs.log"))
  mattr_accessor :logger, default: DEFAULT_LOGGER

  # @!attribute [rw] preserve_job_records
  #   @!scope class
  #   Whether to preserve job records in the database after they have finished (default: +true+).
  #   If you want to preserve jobs for latter inspection, set this to +true+.
  #   If you want to preserve only jobs that finished with error for latter inspection, set this to +:on_unhandled_error+.
  #   If you do not want to preserve jobs, set this to +false+.
  #   When using GoodJob's cron functionality, job records will be preserved for a brief time to prevent duplicate jobs.
  #   @return [Boolean, Symbol, nil]
  mattr_accessor :preserve_job_records, default: true

  # @!attribute [rw] retry_on_unhandled_error
  #   @!scope class
  #   Whether to re-perform a job when a type of +StandardError+ is raised to GoodJob (default: +false+).
  #   If +true+, causes jobs to be re-queued and retried if they raise an instance of +StandardError+.
  #   If +false+, jobs will be discarded or marked as finished if they raise an instance of +StandardError+.
  #   Instances of +Exception+, like +SIGINT+, will *always* be retried, regardless of this attribute's value.
  #   @return [Boolean, nil]
  mattr_accessor :retry_on_unhandled_error, default: false

  # @!attribute [rw] on_thread_error
  #   @!scope class
  #   This callable will be called when an exception reaches GoodJob (default: +nil+).
  #   It can be useful for logging errors to bug tracking services, like Sentry or Airbrake.
  #   @example Send errors to Sentry
  #     # config/initializers/good_job.rb
  #     GoodJob.on_thread_error = -> (exception) { Raven.capture_exception(exception) }
  #   @return [Proc, nil]
  mattr_accessor :on_thread_error, default: nil

  # @!attribute [rw] configuration
  #   @!scope class
  #   Global configuration object for GoodJob.
  #   @return [GoodJob::Configuration, nil]
  mattr_accessor :configuration, default: GoodJob::Configuration.new({})

  # @!attribute [rw] capsule
  #   @!scope class
  #   Global/default execution capsule for GoodJob.
  #   @return [GoodJob::Capsule, nil]
  mattr_accessor :capsule, default: GoodJob::Capsule.new(configuration: configuration)

  # Called with exception when a GoodJob thread raises an exception
  # @param exception [Exception] Exception that was raised
  # @return [void]
  def self._on_thread_error(exception)
    on_thread_error.call(exception) if on_thread_error.respond_to?(:call)
  end

  # Custom Active Record configuration that is class_eval'ed into +GoodJob::BaseRecord+
  # @param block Custom Active Record configuration
  # @return [void]
  #
  # @example
  #   GoodJob.configure_active_record do
  #     connects_to database: :special_database
  #   end
  def self.configure_active_record(&block)
    self._active_record_configuration = block
  end

  mattr_accessor :_active_record_configuration, default: nil

  # Stop executing jobs.
  # GoodJob does its work in pools of background threads.
  # When forking processes you should shut down these background threads before forking, and restart them after forking.
  # For example, you should use +shutdown+ and +restart+ when using async execution mode with Puma.
  # See the {file:README.md#executing-jobs-async--in-process} for more explanation and examples.
  # @param timeout [nil, Numeric] Seconds to wait for actively executing jobs to finish
  #   * +nil+, the scheduler will trigger a shutdown but not wait for it to complete.
  #   * +-1+, the scheduler will wait until the shutdown is complete.
  #   * +0+, the scheduler will immediately shutdown and stop any active tasks.
  #   * +1..+, the scheduler will wait that many seconds before stopping any remaining active tasks.
  # @return [void]
  def self.shutdown(timeout: -1)
    _shutdown_all(Capsule.instances, timeout: timeout)
  end

  # Tests whether jobs have stopped executing.
  # @return [Boolean] whether background threads are shut down
  def self.shutdown?
    Capsule.instances.all?(&:shutdown?)
  end

  # Stops and restarts executing jobs.
  # GoodJob does its work in pools of background threads.
  # When forking processes you should shut down these background threads before forking, and restart them after forking.
  # For example, you should use +shutdown+ and +restart+ when using async execution mode with Puma.
  # See the {file:README.md#executing-jobs-async--in-process} for more explanation and examples.
  # @param timeout [Numeric] Seconds to wait for active threads to finish.
  # @return [void]
  def self.restart(timeout: -1)
    return if configuration.execution_mode != :async && configuration.in_webserver?

    _shutdown_all(Capsule.instances, :restart, timeout: timeout)
  end

  # Sends +#shutdown+ or +#restart+ to executable objects ({GoodJob::Notifier}, {GoodJob::Poller}, {GoodJob::Scheduler}, {GoodJob::MultiScheduler}, {GoodJob::CronManager}, {GoodJob::SharedExecutor})
  # @param executables [Array<Notifier, Poller, Scheduler, MultiScheduler, CronManager, SharedExecutor>] Objects to shut down.
  # @param method_name [Symbol] Method to call, e.g. +:shutdown+ or +:restart+.
  # @param timeout [nil, Numeric] Seconds to wait for actively executing jobs to finish.
  # @param after [Array<Notifier, Poller, Scheduler, MultiScheduler, CronManager, SharedExecutor>] Objects to shut down after initial executables shut down.
  # @return [void]
  def self._shutdown_all(executables, method_name = :shutdown, timeout: -1, after: [])
    if timeout.is_a?(Numeric) && timeout.positive?
      executables.each { |executable| executable.send(method_name, timeout: nil) }

      stop_at = Time.current + timeout
      executables.each { |executable| executable.send(method_name, timeout: [stop_at - Time.current, 0].max) }
    else
      executables.each { |executable| executable.send(method_name, timeout: timeout) }
    end
    return unless after.any? && !timeout.nil?

    if stop_at
      after.each { |executable| executable.shutdown(timeout: [stop_at - Time.current, 0].max) }
    else
      after.each { |executable| executable.shutdown(timeout: timeout) }
    end
  end

  # Destroys preserved job and batch records.
  # By default, GoodJob destroys job records when the job is performed and this
  # method is not necessary. However, when `GoodJob.preserve_job_records = true`,
  # the jobs will be preserved in the database. This is useful when wanting to
  # analyze or inspect job performance.
  # If you are preserving job records this way, use this method regularly to
  # destroy old records and preserve space in your database.
  # @param older_than [nil,Numeric,ActiveSupport::Duration] Jobs older than this will be destroyed (default: +86400+).
  # @param include_discarded [Boolean] Whether or not to destroy discarded jobs (default: per +cleanup_discarded_jobs+ config option)
  # @return [Integer] Number of job execution records and batches that were destroyed.
  def self.cleanup_preserved_jobs(older_than: nil, in_batches_of: 1_000, include_discarded: GoodJob.configuration.cleanup_discarded_jobs?)
    older_than ||= GoodJob.configuration.cleanup_preserved_jobs_before_seconds_ago
    timestamp = Time.current - older_than

    ActiveSupport::Notifications.instrument("cleanup_preserved_jobs.good_job", { older_than: older_than, timestamp: timestamp }) do |payload|
      deleted_jobs_count = 0
      deleted_batches_count = 0
      deleted_executions_count = 0

      jobs_query = GoodJob::Job.finished_before(timestamp).order(finished_at: :asc).limit(in_batches_of)
      jobs_query = jobs_query.succeeded unless include_discarded
      loop do
        active_job_ids = jobs_query.pluck(:active_job_id)
        break if active_job_ids.empty?

        deleted_executions = GoodJob::Execution.where(active_job_id: active_job_ids).delete_all
        deleted_executions_count += deleted_executions

        deleted_jobs = GoodJob::Job.where(active_job_id: active_job_ids).delete_all
        deleted_jobs_count += deleted_jobs
      end

      batches_query = GoodJob::BatchRecord.finished_before(timestamp).limit(in_batches_of)
      batches_query = batches_query.succeeded unless include_discarded
      loop do
        deleted = batches_query.delete_all
        break if deleted.zero?

        deleted_batches_count += deleted
      end

      payload[:destroyed_batches_count] = deleted_batches_count
      payload[:destroyed_executions_count] = deleted_executions_count
      payload[:destroyed_jobs_count] = deleted_jobs_count

      destroyed_records_count = deleted_batches_count + deleted_executions_count + deleted_jobs_count
      payload[:destroyed_records_count] = destroyed_records_count

      destroyed_records_count
    end
  end

  # Perform all queued jobs in the current thread.
  # This is primarily intended for usage in a test environment.
  # Unhandled job errors will be raised.
  # @param queue_string [String] Queues to execute jobs from
  # @param limit [Integer, nil] Maximum number of iterations for the loop
  # @return [void]
  def self.perform_inline(queue_string = "*", limit: nil)
    job_performer = JobPerformer.new(queue_string)
    iteration = 0
    loop do
      break if limit && iteration >= limit

      result = Rails.application.executor.wrap { job_performer.next }
      break unless result
      raise result.unhandled_error if result.unhandled_error

      iteration += 1
    end
  end

  # Tests whether GoodJob can be safely upgraded to v4
  # @return [Boolean]
  def self.v4_ready?
    GoodJob.deprecator.warn(<<~MSG)
      Calling `GoodJob.v4_ready?` is deprecated and will be removed in GoodJob v5.
      If you are reading this deprecation you are already on v4.
    MSG
    true
  end

  # Deprecator for providing deprecation warnings.
  # @return [ActiveSupport::Deprecation]
  def self.deprecator
    @_deprecator ||= begin
      next_major_version = GEM_VERSION.segments[0] + 1
      ActiveSupport::Deprecation.new("#{next_major_version}.0", "GoodJob")
    end
  end

  # Whether all GoodJob migrations have been applied.
  # For use in tests/CI to validate GoodJob is up-to-date.
  # @return [Boolean]
  def self.migrated?
    GoodJob::Job.concurrency_key_created_at_index_migrated?
  end

  # Pause job execution for a given queue or job class.
  # @param queue [String, nil] Queue name to pause
  # @param job_class [String, nil] Job class name to pause
  # @return [void]
  def self.pause(queue: nil, job_class: nil)
    GoodJob::Setting.pause(queue: queue, job_class: job_class)
  end

  # Unpause job execution for a given queue or job class.
  # @param queue [String, nil] Queue name to unpause
  # @param job_class [String, nil] Job class name to unpause
  # @param label [String, nil] Label to unpause
  # @return [void]
  def self.unpause(queue: nil, job_class: nil, label: nil)
    GoodJob::Setting.unpause(queue: queue, job_class: job_class, label: label)
  end

  # Check if job execution is paused for a given queue or job class.
  # @param queue [String, nil] Queue name to check
  # @param job_class [String, nil] Job class name to check
  # @param label [String, nil] Label to check
  # @return [Boolean]
  def self.paused?(queue: nil, job_class: nil, label: nil)
    GoodJob::Setting.paused?(queue: queue, job_class: job_class, label: label)
  end

  # Get a list of all paused queues and job classes
  # @return [Hash] Hash with :queues, :job_classes, :labels arrays of paused items
  def self.paused(type = nil)
    GoodJob::Setting.paused(type)
  end

  # Whether this process was initialized via the GoodJob executable (`$ good_job`)
  # @return [Boolean]
  def self.cli?
    GoodJob::CLI.within_exe?
  end
end

ActiveSupport.run_load_hooks(:good_job, GoodJob)
