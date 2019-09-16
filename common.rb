# frozen_string_literal: true

require 'active_support'
require 'active_support/core_ext'
require 'active_record'
require 'sqlite3'
require 'pathname'
require 'fileutils'
require 'open3'
require 'pry'
require 'mini_exiftool'
require 'ruby-progressbar'

DATABASE_FILE = 'tmp/database.sqlite3'

ActiveRecord::Base.establish_connection(
  adapter: 'sqlite3',
  database: DATABASE_FILE,
)

ActiveRecord::Schema.define do
  self.verbose = false

  create_table :photos, force: :cascade do |t|
    t.string :file, null: false
    t.json :exif_attributes
    t.boolean :broken, null: false

    t.index :file
    t.index :exif_attributes
    t.index :broken

    t.timestamps
  end
end

class Photo < ActiveRecord::Base
  scope :broken, -> { where broken: true }
  scope :correct, -> { where broken: false }
end

class FixTimestamp
  attr_reader :source, :destination

  def initialize(source, destination)
    @source = source
    @destination = destination
  end

  def build_index
    progressbar = create_progressbar(files.length)
    progressbar.log("Building index")

    files.each_with_index do |file, index|
      progressbar.progress = index
      broken, exif_attributes = process_file(file, progressbar)

      Photo.create!(
        file: file,
        exif_attributes: exif_attributes,
        broken: broken,
      )
    end

    progressbar.log("Building index completed. Broken: #{Photo.broken.count}. Correct: #{Photo.correct.count}")
    progressbar.finish
  end

  def update_index
    photos = Photo.broken.to_a

    if photos.length.zero?
      puts "No broken image in the index, not updating"
      return
    end

    progressbar = create_progressbar(photos.length)
    progressbar.log("Updating index")

    photos.each_with_index do |photo, index|
      progressbar.progress = index
      broken, exif_attributes = process_file(photo.file, progressbar)

      photo.update!(
        exif_attributes: exif_attributes,
        broken: broken,
      )
    end

    progressbar.log("Updating index completed. Broken: #{Photo.broken.count}. Correct: #{Photo.correct.count}")
    progressbar.finish
  end

  def process_file(file, progressbar)
    data = data_from_file(file)
    broken = false

    if data.length.zero?
      progressbar.log("[WARNING] No data for `#{file}`")
      broken = true
    end

    if data.length > 1
      progressbar.log("[WARNING] `#{data.length}` data found for `#{file}`")
      broken = true
    end

    exif_attributes = exif_attributes_from_data(data.first) unless broken
    [broken, exif_attributes]
  end

  # def write_xmp
  #   new_file = new_file_name(image_file, source, destination)
  #   FileUtils.mkdir_p(File.dirname(new_file))
  #   FileUtils.cp_r(image_file, new_file, remove_destination: true, verbose: false)

  #   # NOTE: we're using the original image_file, because moving the photo can result
  #   # in updated timestamps
  #   photo = MiniExiftool.new(image_file)
  #   current_exif_attributes = {}

  #   new_exif_attributes.each do |name, _value|
  #     current_exif_attributes[name.to_s] = photo.send(name)
  #   end

  #   progressbar.log("Updating `#{new_file}` from `#{current_exif_attributes}` to `#{new_exif_attributes}`")

  #   output, exitstatus = update_exif_data(new_file, new_exif_attributes)

  #   unless exitstatus == 0
  #     progressbar.log("[WARNING] EXIF saving had errors for photo `#{new_file}`: #{output}")
  #   end
  # end

  def data_from_file(_file)
    raise 'implement this'
  end

  def exif_attributes_from_data(_data)
    raise 'implement this'
  end

  def files
    @files ||= Dir.glob(File.join(source, '**/*')).select do |maybe_file|
      File.file?(maybe_file)
    end.sort
  end

  def new_file_name(filename, source, destination)
    absolute_path = Pathname.new(File.expand_path(filename))
    project_root  = Pathname.new(File.expand_path(source))
    relative      = absolute_path.relative_path_from(project_root)
    File.join(destination, relative)
  end

  def create_progressbar(number)
    ProgressBar.create(
      format: '%a -%e %P% %B Processed: %c from %C',
      total: number,
    )
  end

  def update_exif_data(file, new_exif_attributes)
    command = "exiftool '#{file}'"

    new_exif_attributes.each do |name, value|
      command += %( -#{name}="#{value}")
    end

    command += '-P -overwrite_original'

    output, status = Open3.capture2e(command)

    [output, status.exitstatus]
  end
end
