# frozen_string_literal: true

require 'sqlite3'
require 'active_support'
require 'active_support/core_ext'
require 'pathname'
require 'fileutils'
require 'open3'
require 'pry'
require 'mini_exiftool'
require 'ruby-progressbar'

class FixTimestamp
  attr_reader :source, :destination

  def initialize(source, destination)
    @source = source
    @destination = destination
  end

  def call
    files.each_with_index do |image_file, index|
      progressbar.progress = index
      data = data_from_file(image_file)

      if data.empty?
        progressbar.log("[WARNING] No database entry found for `#{image_file}`. Skipping")
        next
      end

      if data.length > 1
        progressbar.log("[WARNING] `#{data.length}` database entry found for `#{image_file}`. Skipping")
        next
      end

      data = data.first

      new_exif_attributes = exif_attributes_from_data(data)

      new_file = new_file_name(image_file, source, destination)
      FileUtils.mkdir_p(File.dirname(new_file))
      FileUtils.cp_r(image_file, new_file, remove_destination: true, verbose: false)

      # NOTE: we're using the original image_file, because moving the photo can result
      # in updated timestamps
      photo = MiniExiftool.new(image_file)
      current_exif_attributes = {}

      new_exif_attributes.each do |name, _value|
        current_exif_attributes[name.to_s] = photo.send(name)
      end

      progressbar.log("Updating `#{new_file}` from `#{current_exif_attributes}` to `#{new_exif_attributes}`")

      output, exitstatus = update_exif_data(new_file, new_exif_attributes)

      unless exitstatus == 0
        progressbar.log("[WARNING] EXIF saving had errors for photo `#{new_file}`: #{output}")
      end
    end

    progressbar.finish
  end

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

  def progressbar
    @progressbar ||= ProgressBar.create(
      format: '%a -%e %P% %B Processed: %c from %C',
      total: files.length
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
