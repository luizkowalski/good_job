# frozen_string_literal: true

require 'rails_helper'

describe GoodJob::CronEntry do
  subject(:entry) { described_class.new(params) }

  let(:params) do
    {
      key: 'test',
      cron: "* * * * *",
      class: "TestJob",
      args: [42],
      kwargs: { name: "Alice" },
      set: { queue: 'test_queue' },
      description: "Something helpful",
    }
  end

  before do
    stub_const 'TestJob', (Class.new(ActiveJob::Base) do
      def perform(meaning, name:)
        # nothing
      end
    end)
  end

  describe '#initialize' do
    it 'raises an argument error if cron does not parse to a Fugit::Cron instance' do
      expect { described_class.new(cron: '2017-12-12') }.to raise_error(ArgumentError)
    end
  end

  describe '#all' do
    it 'returns all entries' do
      expect(described_class.all).to be_a(Array)
    end
  end

  describe '#find' do
    it 'returns the entry with the given key' do
      expect(described_class.find('example')).to be_a(described_class)
    end

    it 'raises ActiveRecord:RecordNotFound if the key does not exist' do
      expect { described_class.find('nothing') }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe '#key' do
    it 'returns the cron key' do
      expect(entry.key).to eq('test')
    end
  end

  describe '#next_at' do
    it 'returns a timestamp of the next time to run' do
      expect(entry.next_at).to eq(Time.current.at_beginning_of_minute + 1.minute)
    end

    context 'when the cron is a proc' do
      let(:time_at) { 1.minute.from_now }
      let(:my_proc) { instance_double(Proc, call: time_at, arity: 1) }
      let(:params) { super().merge(cron: my_proc) }

      it 'is executed' do
        expect(entry.next_at).to eq time_at
        expect(my_proc).to have_received(:call).with(nil)
      end
    end
  end

  describe '#within' do
    it 'returns an array of timestamps for the time period' do
      expect(entry.within(2.minutes.ago..Time.current)).to eq([Time.current.at_beginning_of_minute - 1.minute, Time.current.at_beginning_of_minute])
    end
  end

  describe '#enabled' do
    it 'is enabled by default' do
      expect(entry).to be_enabled
    end

    it 'can be enabled and disabled' do
      entry.disable
      expect(entry).not_to be_enabled

      entry.enable
      expect(entry).to be_enabled
    end

    context "when enabled_by_default=false" do
      let(:params) { super().merge(enabled_by_default: false) }

      it 'is disabled by default' do
        expect(entry).not_to be_enabled
      end

      it 'can be enabled and disabled' do
        entry.enable
        expect(entry).to be_enabled

        entry.disable
        expect(entry).not_to be_enabled
      end
    end

    context 'when a lambda' do
      let(:params) { super().merge(enabled_by_default: -> { false }) }

      it 'is disabled by default' do
        expect(entry).not_to be_enabled
      end
    end
  end

  describe 'display_schedule' do
    it 'returns the cron expression' do
      expect(entry.display_schedule).to eq('* * * * *')
    end

    it 'returns the cron expression for a schedule parsed using natual language' do
      entry = described_class.new(cron: 'every weekday at five')
      expect(entry.display_schedule).to eq('0 5 * * 1-5')
    end

    it 'generates a schedule provided via a block' do
      entry = described_class.new(cron: ->(last_run) {})
      expect(entry.display_schedule).to eq('Lambda/Callable')
    end
  end

  describe '#fugit' do
    it 'parses the cron configuration using fugit' do
      allow(Fugit).to receive(:parse).and_call_original

      entry.send(:fugit)

      expect(Fugit).to have_received(:parse).with('* * * * *')
    end

    it 'returns an instance of Fugit::Cron' do
      expect(entry.send(:fugit)).to be_instance_of(Fugit::Cron)
    end
  end

  describe '#enqueue' do
    include ActiveJob::TestHelper

    before do
      ActiveJob::Base.queue_adapter = :test
    end

    it 'enqueues a job with the correct parameters' do
      expect do
        entry.enqueue
      end.to have_enqueued_job(TestJob).with(42, name: 'Alice').on_queue('test_queue')
    end

    it 'enqueues a job with I18n default locale' do
      I18n.default_locale = :nl

      I18n.with_locale(:en) { entry.enqueue }

      expect(enqueued_jobs.last["locale"]).to eq("nl")
    ensure
      I18n.default_locale = :en
    end

    it 'can handle a proc for a class value that enqueues a job directly' do
      ActiveJob::Base.queue_adapter = GoodJob::Adapter.new(execution_mode: :external)

      cron_at = Time.current

      entry = described_class.new(params.merge(class: -> { TestJob.set(queue: "direct").perform_later(42, name: 'Direct') }))
      entry.enqueue(cron_at)

      job = GoodJob::Job.last
      expect(job).to have_attributes(
        job_class: 'TestJob',
        cron_at: be_within(0.001.seconds).of(cron_at),
        queue_name: 'direct'
      )
    end

    describe 'job execution' do
      it 'executes the job properly' do
        perform_enqueued_jobs do
          expect { entry.enqueue }.not_to raise_error
        end
      end
    end

    describe "adapter integration" do
      before do
        ActiveJob::Base.queue_adapter = GoodJob::Adapter.new(execution_mode: :external)
      end

      it 'assigns cron_key and cron_at to the execution' do
        cron_at = 10.minutes.ago
        entry.enqueue(cron_at)

        job = GoodJob::Job.last
        expect(job.cron_key).to eq 'test'
        expect(job.cron_at).to be_within(0.001.seconds).of(cron_at)
      end

      it 'gracefully handles a duplicate enqueue, for example across multiple processes' do
        cron_at = 10.minutes.ago

        expect do
          entry.enqueue(cron_at)
          entry.enqueue(cron_at)
        end.to change(GoodJob::Job, :count).by(1)
      end
    end
  end

  describe '#display_properties' do
    let(:params) do
      {
        key: 'test',
        cron: "* * * * *",
        class: "TestJob",
        args: [42, { name: "Alice" }],
        set: -> { { queue: 'test_queue' } },
        description: "Something helpful",
      }
    end

    it 'returns a hash of properties' do
      expect(entry.display_properties).to eq({
                                               key: 'test',
        cron: "* * * * *",
        class: "TestJob",
        args: [42, { name: "Alice" }],
        set: "Lambda/Callable",
        description: "Something helpful",
                                             })
    end
  end
end
