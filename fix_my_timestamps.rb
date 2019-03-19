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
  base_file = File.basename(file)

  # TODO: from the file AND the timestamp get the data
  # multiple photos can have the same name so they will exported in finder as
  # IMG (0), IMG (1), IMG (2) but stored in the db as IMG

  # NOTE: strange date conversion
  # this is due to apple date base starting at 2001-01-01
  # https://apple.stackexchange.com/questions/114168/dates-format-in-messages-chat-db
  query = <<~SQL
    SELECT
      datetime(createDate + strftime('%s','2001-01-01'), 'unixepoch') as date

    FROM
      RKMaster

    WHERE
      fileName = ?
  SQL

  database.execute(query, base_file)
end

def new_file_name(filename, source, dest)
  absolute_path = Pathname.new(File.expand_path(filename))
  project_root  = Pathname.new(File.expand_path(source))
  relative      = absolute_path.relative_path_from(project_root)
  File.join(dest, relative)
end

def update_exif_data(file, timestamp)
  command = <<~CMD
    exiftool #{file} -filemodifydate="#{timestamp}" -P -overwrite_original
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
end

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

  timestamp = Time.parse("#{data.fetch('date')} UTC").getlocal

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
