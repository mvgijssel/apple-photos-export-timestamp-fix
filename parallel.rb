require 'concurrent'
require 'concurrent-edge'
require 'ruby-progressbar'
require 'pry'

FUTURE_POOL = Concurrent::FixedThreadPool.new(8000)

class Progress < Concurrent::Actor::Context
  attr_reader :progress_bar

  def initialize(total_count)
    @progress_bar = ProgressBar.create(
      format: '%a -%e %P% %B Processed: %c from %C',
      total: total_count,
    )
  end

  def on_message(message)
    case message
    when :increment
      progress_bar.increment
      progress_bar.progress

    when :finish
      progress_bar.finish
      progress_bar.progress

    else
      pass
    end
  end
end

total_count = 30_000
progress = Progress.spawn(name: :progress, args: total_count)

promises = total_count.times.map do |n|
  Concurrent::Promises.future_on(FUTURE_POOL) do
    sleep 1
    progress.tell(:increment)
    1
  end
end

Concurrent::Promises.zip(*promises).value

progress.ask!(:finish)
