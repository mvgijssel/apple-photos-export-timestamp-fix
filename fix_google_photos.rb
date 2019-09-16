#!/usr/bin/env ruby

require_relative './common'

class FixGoogleTimestamp < FixTimestamp
  attr_reader :json_files

  def files
    @files ||= begin
                 all_files = super

                 image_files = []
                 @json_files = Hash.new { |memo, key| memo[key] = [] }

                 all_files.each do |file|
                   extension = File.extname(file)

                   case extension.downcase
                   when '.jpg'
                     image_files << file
                   when '.json'
                     # NOTE: we're making a mapping between the image file
                     # and the json file, to speedup lookup
                     # An image looks like "some_image.jpg"
                     # and the related json "some_image.jpg.json"
                     image_file = file.chomp(extension)
                     json_files[image_file] << file
                   else
                     progressbar.log("[WARNING] Unknown extension `#{extension.downcase}` for `#{file}`, skipping")
                   end
                 end

                 image_files
               end
  end

  def data_from_file(image_file)
    json_files[image_file].map do |json_file|
      JSON.parse File.readlines(json_file).join
    end
  end

  def exif_attributes_from_data(data)
    create_timestamp = Time.at(
      data.fetch('photoTakenTime').fetch('timestamp').to_f
    ).getlocal

    modify_timestamp = Time.at(
      data.fetch('modificationTime').fetch('timestamp').to_f
    ).getlocal

    {
      'filemodifydate' => modify_timestamp,
      'filecreatedate' => create_timestamp,
    }
  end
end


if ARGV.length != 2
  puts "Please provide two arguments: `fix_google_photos.rb src/ dest/`"
  exit 1
end

source = ARGV[0]
dest = ARGV[1]

fix = FixGoogleTimestamp.new(source, dest)
fix.build_index
fix.update_index
