require 'active_support'
require 'active_support/core_ext'
require 'mini_exiftool'

require_relative 'progress'

FUTURE_POOL = Concurrent::FixedThreadPool.new(8000)

class FixGoogleTimestamp
  attr_reader :destination

  def initialize(destination)
    @destination = destination
  end

  def call
    media_files = {}
    data_files = {}
    unknown_extensions = Hash.new 0

    Dir.glob(File.join(destination, '**/*')).each do |maybe_file|
      next unless File.file?(maybe_file)

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

    binding.pry

    progress = Progress.spawn(name: :progress, args: image_files.length)

    promises = image_files.map do |image_file|
      Concurrent::Promises.future_on(FUTURE_POOL) do
        progress.tell action: :increment
        progress.tell action: :log, value: image_file
      end
    end

    Concurrent::Promises.zip(*promises).value

    progress.ask! action: :finish
  end
end
