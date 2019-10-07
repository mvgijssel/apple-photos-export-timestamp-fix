require 'active_support'
require 'active_support/core_ext'
require 'mini_exiftool'

require 'pathname'
require 'fileutils'
require 'oj'
require 'posix/spawn'

require_relative 'progress'

FUTURE_POOL = Concurrent::FixedThreadPool.new(100)

class FixAppleTimestamp
  attr_reader :source
  attr_reader :destination

  def initialize(source, destination)
    @source = source
    @destination = destination
  end

  def call
    puts "yeah buddy"
  end
end
