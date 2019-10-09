class FixDuplicates
  attr_reader :keep_folder
  attr_reader :trash_folder
  attr_reader :verbose

  def initialize(keep_folder, trash_folder, verbose)
    @keep_folder = keep_folder
    @trash_folder = trash_folder
    @verbose = verbose
  end

  def call
    puts "Yeah buddy"
  end
end
