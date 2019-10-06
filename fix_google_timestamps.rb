require 'active_support'
require 'active_support/core_ext'
require 'mini_exiftool'

require 'pathname'
require 'fileutils'
require 'oj'
require 'posix/spawn'

require_relative 'progress'

FUTURE_POOL = Concurrent::FixedThreadPool.new(100)

class FixGoogleTimestamp
  attr_reader :source
  attr_reader :destination

  def initialize(source, destination)
    @source = source
    @destination = destination
  end

  def call
    media_files = {}
    data_files = {}
    unknown_extensions = Hash.new 0

    Dir.glob(File.join(source, '**/*')).each do |maybe_file|
      next unless File.file?(maybe_file)
      next if maybe_file.start_with?(destination)

      file = maybe_file
      file_extension = File.extname(file)

      case file_extension.downcase
      when '.jpg',
           '.mp4',
           '.mov',
           '.gif',
           '.heic',
           '.png',
           '.jpeg',
           '.3gp'

        media_files[file] = nil
      when '.json'

        data_files[file] = nil

        # # NOTE: we're making a mapping between the image file
        # # and the json file, to speedup lookup
        # # An image looks like "some_image.jpg"
        # # and the related json "some_image.jpg.json"
        # image_file = file.chomp(file_extension)
        # json_files[image_file] << file

      else
        unknown_extensions[file_extension.downcase] += 1
      end
    end

    unless unknown_extensions.length.zero?
      puts "Unknown extensions:"

      unknown_extensions.each do |unknown_extension, count|
        puts "#{unknown_extension}: #{count}"
      end

      raise "Stopping"
    end

    media_files_missing_data = []
    media_files_omitted = []

    media_files.each do |media_file, _value|
      file_name = "#{media_file}.json"
      base_name = File.basename(media_file)
      file_directory = File.dirname(media_file)
      data_file = data_files.key?(file_name) ? file_name : nil

      if data_file.nil?
        # translates:
        # 2012-04-30.jpg
        # into
        # 2012-04-30.json
        new_base_name = File.basename(base_name, File.extname(base_name)) + '.json'
        file_name = File.join(file_directory, new_base_name)
        data_file = data_files.key?(file_name) ? file_name : nil
      end

      if data_file.nil?
        # translates:
        # 20160312_142135(1).jpg
        # into
        # 20160312_142135.jpg(1).json
        new_base_name = base_name.gsub(/^(.*?)(\(\d+\))\.(.*)$/, '\1.\3\2.json')
        file_name = File.join(file_directory, new_base_name)
        data_file = data_files.key?(file_name) ? file_name : nil
      end

      if data_file.nil?
        # translate
        # IMG_6492(1).JPG
        # into
        # IMG_6492.JPG.json
        #
        # If data exists for the updated file name, means there's a duplicate
        # photo and we don't need to process it.
        new_base_name = base_name.gsub(/\(\d+\)/, '') + '.json'
        file_name = File.join(file_directory, new_base_name)

        if data_files.key?(file_name)
          media_files_omitted << media_file
          media_files.delete media_file
          next
        end
      end

      if data_file.nil?
        # translate
        # 20140827_185414-bewerkt.jpg
        # into
        # 20140827_185414.jpg.json
        #
        # If data exists for the updated file name, means there's a duplicate
        # photo and we don't need to process it.
        new_base_name = base_name.gsub(/-bewerkt/, '') + '.json'
        file_name = File.join(file_directory, new_base_name)

        if data_files.key?(file_name)
          media_files_omitted << media_file
          media_files.delete media_file
          next
        end
      end

      if data_file
        media_files[media_file] = data_file
      else
        media_files_missing_data << media_file
      end
    end

    unless media_files_missing_data.length.zero?
      albums_with_missing_data = Hash.new { |memo, key| memo[key] = [] }

      media_files_missing_data.each do |media_file|
        directory = File.dirname(media_file)
        _rest, album = File.split(directory)

        albums_with_missing_data[album] << media_file
      end

      albums_with_missing_data = albums_with_missing_data.sort_by { |_key, value| -value.length }.to_h

      message = "Albums with missing json files:\n"
      albums_with_missing_data.each do |album, data|
        message += "  #{album}: #{data.length}\n"
        message += "    #{data}\n\n"
      end

      raise message
    end

    unless media_files_omitted.length.zero?
      puts "Skipping (#{media_files_omitted.length}) duplicate files"
    end

    puts "Moving to #{destination}"

    progress = Progress.spawn(name: :progress, args: media_files.length)

    promises = media_files.map do |media_file, data_file|
      Concurrent::Promises.future_on(FUTURE_POOL) do
        begin
          # Translate
          # source: /some/folder
          # image: /some/folder/image.jpg
          # relative: image.jpg
          relative_path = Pathname.new(media_file).relative_path_from Pathname.new(source)
          media_file_final = File.join(destination, relative_path)
          media_file_directory = File.dirname(media_file_final)
          FileUtils.mkdir_p media_file_directory
          FileUtils.copy(media_file, media_file_final)

          # load data file
          data = Oj.load File.read(data_file)

          create_timestamp = Time.at(
            data.fetch('photoTakenTime').fetch('timestamp').to_f
          ).getlocal

          modify_timestamp = Time.at(
            data.fetch('modificationTime').fetch('timestamp').to_f
          ).getlocal

          new_exif_attributes = {
            'filemodifydate' => modify_timestamp,
            'filecreatedate' => create_timestamp,
          }

          # change media file
          command = "exiftool '#{media_file_final}'"

          new_exif_attributes.each do |name, value|
            command += %( -#{name}="#{value}")
          end

          command += '-P -overwrite_original'

          child = POSIX::Spawn::Child.new(command)

          unless child.status.exitstatus.zero?
            progress.tell action: :log, value: child.err
          end

        rescue => e
          progress.tell action: :log, value: e.message
        end

        progress.tell action: :increment
      end
    end

    Concurrent::Promises.zip(*promises).value!

    progress.ask! action: :finish
  end
end
