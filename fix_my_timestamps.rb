#!/usr/bin/env ruby

require 'sqlite3'
require 'pathname'
require 'fileutils'
require 'open3'
require 'mini_exiftool'
require 'ruby-progressbar'

if ARGV.length != 3
  puts "Please provide three arguments: `fix_my_timestamps src/ dest/ library`"
  exit 1
end

def data_from_library(database, file)
  original_file_size = File.size(file)
  normalised_file_name = File.basename(file)

  # NOTE: after exporting photos from Apple photo
  # the photos can have a suffix when the name is the same, like
  # IMG, IMG (1), IMG (2)
  # we need to remove this added suffix because this is not
  # the way it is stored in the library
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

def new_file_name(filename, source, dest)
  absolute_path = Pathname.new(File.expand_path(filename))
  project_root  = Pathname.new(File.expand_path(source))
  relative      = absolute_path.relative_path_from(project_root)
  File.join(dest, relative)
end

# TODO: write to the right field! Necessary for Google Photo
def update_exif_data(file, timestamp)
  command = <<~CMD
    exiftool '#{file}' \
      -filemodifydate="#{timestamp}" \
      -P -overwrite_original
  CMD

  output, status = Open3.capture2e(command)

  [output, status.exitstatus]
end

source = ARGV[0]
dest = ARGV[1]
library = ARGV[2]
database_path = "photos.db" # TODO: based on library
database = SQLite3::Database.new(database_path)
database.results_as_hash = true

files = Dir.glob(File.join(source, "**/*")).select do |maybe_file|
  File.file?(maybe_file)
end.sort

progressbar = ProgressBar.create(
  format: "%a -%e %P% %B Processed: %c from %C",
  total: files.length,
)

files.each_with_index do |file, index|
  progressbar.progress = index
  data = data_from_library(database, file)

  if data.length == 0
    progressbar.log("[WARNING] No database entry found for `#{file}`. Skipping")
    next
  end

  if data.length > 1
    progressbar.log("[WARNING] `#{data.length}` database entry found for `#{file}`. Skipping")
    next
  end

  data = data.first

  timestamp = Time.parse("#{data.fetch('fileCreationDate')} UTC").getlocal

  new_file = new_file_name(file, source, dest)
  FileUtils.mkdir_p(File.dirname(new_file))
  FileUtils.cp_r(file, new_file, remove_destination: true, verbose: false)

  photo = MiniExiftool.new(file)

  progressbar.log("Updating `#{new_file}` from `#{photo.filemodifydate}` to `#{timestamp}`")

  output, exitstatus = update_exif_data(new_file, timestamp)

  unless exitstatus == 0
    progressbar.log("[WARNING] EXIF saving had errors for photo `#{file}`: #{output}")
  end
end

progressbar.finish
