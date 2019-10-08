require 'active_support'
require 'active_support/core_ext'
require 'sqlite3'
require 'fileutils'

require_relative 'progress'
require_relative 'photo_utils'

FUTURE_POOL = Concurrent::FixedThreadPool.new(100)

class FixAppleTimestamp
  attr_reader :source
  attr_reader :destination
  attr_reader :database
  attr_reader :temp_directory
  attr_reader :verbose

  def initialize(source, destination, existing_database_path, verbose)
    @source = source
    @destination = destination
    @verbose = verbose
    @temp_directory = File.join(destination, 'tmp')

    database_path = File.join(temp_directory, 'photos.db')
    FileUtils.mkdir_p(File.dirname(database_path))
    FileUtils.copy(existing_database_path, database_path)
    @database = SQLite3::Database.new(database_path)
    database.results_as_hash = true
  end

  def call
    media_files = {}
    media_files_missing_data = []
    media_files_unknown_data = []

    Dir.glob(File.join(source, '**/*')).each do |maybe_file|
      next unless File.file?(maybe_file)
      next if maybe_file.start_with?(destination)

      file = maybe_file
      data = data_from_file(file)

      if data.length == 0
        media_files_missing_data << file
        next
      end

      if data.length > 1
        media_files_unknown_data << file
        next
      end

      data = data.first
      create_timestamp = Time.parse("#{data.fetch('fileCreationDate')} UTC").getlocal
      modify_timestamp = Time.parse("#{data.fetch('fileModificationDate')} UTC").getlocal

      media_files[file] = {
        create_timestamp: create_timestamp,
        modify_timestamp: modify_timestamp,
      }
    end

    unless media_files_missing_data.length.zero?
      albums_with_missing_data = Hash.new { |memo, key| memo[key] = [] }

      media_files_missing_data.each do |media_file|
        directory = File.dirname(media_file)
        _rest, album = File.split(directory)

        albums_with_missing_data[album] << media_file
      end

      albums_with_missing_data = albums_with_missing_data.sort_by { |_key, value| -value.length }.to_h

      message = "Total missing files #{media_files_missing_data.length}:\n"
      message += "Albums with missing json files:\n"
      albums_with_missing_data.each do |album, data|
        message += "  #{album}: #{data.length}\n"

        data.each do |data_item|
          message += "    #{data_item}\n"
        end

        message += "\n"
      end

      raise message
    end

    progress = Progress.spawn(name: :progress, args: media_files.length)

    promises = media_files.map do |file, data|
      Concurrent::Promises.future_on(FUTURE_POOL) do
        begin
          file = PhotoUtils.copy_file(file, source, destination)

          PhotoUtils.update_timestamps(
            file,
            data.fetch(:create_timestamp),
            data.fetch(:modify_timestamp),
          )
        rescue => e
          message = "#{file} - #{e.message}"
          message += e.backtrace.join("\n") if verbose

          progress.tell action: :error, value: message
        end

        progress.tell action: :increment
      end
    end

    Concurrent::Promises.zip(*promises).value!

    progress.ask! action: :finish
  ensure
    FileUtils.rm_rf(temp_directory)
  end

  private

  def data_from_file(file)
    original_file_size = File.size(file)
    normalised_file_name = File.basename(file)

    # NOTE: after exporting photos from Apple photo
    # the photos can have a suffix when the name is the same, like
    # IMG, IMG (1), IMG (2)
    # we need to remove this added suffix because this is not
    # the way it is stored in the library database
    normalised_file_name = normalised_file_name.gsub(/ \(\d+\)/, "")

    # NOTE: strange date conversion
    # this is due to apple date base starting at 2001-01-01
    # https://apple.stackexchange.com/questions/114168/dates-format-in-messages-chat-db

    # In a proper photo these are available and probably used by Google photos
    # modifydate
    # createdate
    # datetimeoriginal
    query = <<~SQL
      SELECT
        datetime(createDate + strftime('%s','2001-01-01'), 'unixepoch') as createDate,
        datetime(fileModificationDate + strftime('%s','2001-01-01'), 'unixepoch') as fileModificationDate,
        datetime(imageDate + strftime('%s','2001-01-01'), 'unixepoch') as imageDate,
        datetime(fileCreationDate + strftime('%s','2001-01-01'), 'unixepoch') as fileCreationDate,
        originalFileSize

      FROM
        RKMaster

      WHERE
        -- fileName = 'DSC_0407.JPG'
        -- fileName = 'IMG_7314.JPG'
        -- originalFileSize = 6669176

        fileName = ? AND originalFileSize = ?
    SQL

    database.execute(query, normalised_file_name, original_file_size)
  end
end
