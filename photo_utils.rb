require 'mini_exiftool'
require 'oj'
require 'fileutils'
require 'pathname'
require 'posix/spawn'
require 'shellwords'

class PhotoUtils
  class << self
    def copy_file(file, source, destination)
      # Translate
      # source: /some/folder
      # image: /some/folder/image.jpg
      # relative: image.jpg
      relative_path = Pathname.new(file).relative_path_from Pathname.new(source)
      new_file = File.join(destination, relative_path)
      new_file_directory = File.dirname(new_file)
      FileUtils.mkdir_p new_file_directory
      FileUtils.copy(file, new_file)
      new_file
    end

    def update_extension(file, new_extension)
      dir_name = File.dirname(file)
      new_base_name = File.basename(File.basename(file), File.extname(file)) + ".#{new_extension}"
      File.join(dir_name, new_base_name)
    end

    def move_file(file, source, destination)
      # Translate
      # source: /some/folder
      # image: /some/folder/image.jpg
      # relative: image.jpg
      relative_path = Pathname.new(file).relative_path_from Pathname.new(source)
      new_file = File.join(destination, relative_path)
      new_file_directory = File.dirname(new_file)
      FileUtils.mkdir_p new_file_directory
      FileUtils.move(file, new_file)
      new_file
    end

    def update_timestamps(media_file, create_timestamp, modify_timestamp)
      file_extension = File.extname(media_file)

      new_exif_attributes = {}

      # NOTE that we're setting both the modification and creation date to the create timestamp.
      # The modification timestamp is mostly wrong and will be chosen when the creation time
      # is missing in the EXIF data
      basic_exif_attributes = {
        'file:filemodifydate' => create_timestamp,
        'file:filecreatedate' => create_timestamp,
      }

      new_exif_attributes.merge! basic_exif_attributes

      unless file_extension.downcase == '.heic'
        new_exif_attributes.merge!({
          'exif:datetimeoriginal' => create_timestamp,
          'exif:createdate' => create_timestamp,
          'exif:modifydate' => modify_timestamp,
        })
      end

      # change media file
      update_command = "exiftool #{Shellwords.escape(media_file)}"

      new_exif_attributes.each do |name, value|
        update_command += %( -#{name}="#{value}")
      end

      update_command += '-P -overwrite_original'
      child = POSIX::Spawn::Child.new(update_command)

      unless child.status.exitstatus.zero?
        if child.err.include?("Error: Not a valid PNG (looks more like a JPEG)")
          # Rename the file to jpg, as indicated by the error message
          # and try to update the file again

          update_extension media_file, 'jpg'
          FileUtils.move(media_file, updated_extension_media_file)

          update_command = "exiftool #{Shellwords.escape(updated_extension_media_file)}"

          new_exif_attributes.each do |name, value|
            update_command += %( -#{name}="#{value}")
          end

          update_command += '-P -overwrite_original'
          child = POSIX::Spawn::Child.new(update_command)

          unless child.status.exitstatus.zero?
            raise "PNG_FAIL: #{child.err}"
          end
        else
          # make a copy of the file
          temp_copy = "#{media_file}_TEMP"
          FileUtils.copy(media_file, temp_copy)

          # remove all exif data on the TEMP
          nuke_command = "exiftool -exif:all= '#{temp_copy}' -P -overwrite_original"
          child = POSIX::Spawn::Child.new(nuke_command)

          if child.status.exitstatus.zero?
            # copy all tags from original
            copy_command = "exiftool -tagsfromfile #{Shellwords.escape(media_file)} -all:all #{Shellwords.escape(temp_copy)} -P -overwrite_original"
            child = POSIX::Spawn::Child.new(copy_command)

            if child.status.exitstatus.zero?
              # make TEMP the original
              FileUtils.move(temp_copy, media_file)

              # run actual update
              child = POSIX::Spawn::Child.new(update_command)

              unless child.status.exitstatus.zero?
                raise "PRISTINE_FAIL: #{child.err}"
              end
            else
              # Remove the TEMP file
              FileUtils.remove(temp_copy)

              raise "OVERWRITE_FAIL: #{child.err}"
            end
          else
            # Seems the EXIF is super duper broken
            # so let's only update the file attributes
            #
            # Remove the TEMP file
            FileUtils.remove(temp_copy)

            update_command = "exiftool #{Shellwords.escape(media_file)}"

            basic_exif_attributes.each do |name, value|
              update_command += %( -#{name}="#{value}")
            end

            update_command += '-P -overwrite_original'
            child = POSIX::Spawn::Child.new(update_command)

            unless child.status.exitstatus.zero?
              raise "BROKEN_FAIL: #{child.err}"
            end
          end
        end
      end
    end
  end
end
