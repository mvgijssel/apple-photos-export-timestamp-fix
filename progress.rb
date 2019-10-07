require 'concurrent'
require 'concurrent-edge'
require 'ruby-progressbar'

class Progress < Concurrent::Actor::Context
  attr_reader :progress_bar

  def initialize(total_count)
    @progress_bar = ProgressBar.create(
      format: '%a -%e %P% %B Processed: %c from %C',
      total: total_count,
    )
  end

  def on_message(message)
    case message.fetch(:action)
    when :increment
      progress_bar.increment
      progress_bar.progress

    when :log
      progress_bar.log("[INFO][#{message.fetch(:tag)}]: #{message.fetch(:value)}")

    when :error
      progress_bar.log("[ERROR][#{message.fetch(:tag)}]: #{message.fetch(:value)}")

    when :finish
      progress_bar.finish
      progress_bar.progress

    else
      pass
    end
  end
end
