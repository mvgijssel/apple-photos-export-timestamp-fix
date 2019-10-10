require_relative 'photo_utils'

class FixDuplicates
  attr_reader :keep_directories
  attr_reader :delete_directories
  attr_reader :trash_directory
  attr_reader :duplicate_data_file
  attr_reader :verbose

  def initialize(keep_directories, delete_directories, trash_directory, duplicate_data_file, verbose)
    @keep_directories = keep_directories
    @delete_directories = delete_directories
    @trash_directory = trash_directory
    @duplicate_data_file = duplicate_data_file
    @verbose = verbose
  end

  def call
    lines = File.readlines(duplicate_data_file)
    lines = lines.reject do |line|
      line.strip!

      line.include?('Started database...') ||
        line.include?('Number of duplicates:') ||
        line.include?('Stopped database...')
    end

    json = lines.join("")

    # Remove escaped single quotes used in file paths with quotes
    json.gsub!(/''/, '')
    json.gsub!(/'(.*?)'/, '"\1"')

    duplicate_data = JSON.parse(json)
    total_deleted_files = 0
    total_deleted_associated_mov_files = 0
    total_skipped_files = 0

    duplicate_data.each do |duplicate_data_item|
      items = duplicate_data_item.fetch('items')

      items_without_keep_directories = items.reject do |item|
        keep_directories.any? do |keep_directory|
          item.fetch('file_name').start_with? keep_directory
        end
      end

      items_without_keep_directories.each do |item|
        delete_directories.each do |delete_directory|
          file_name = item.fetch('file_name')
          next unless file_name.start_with? delete_directory

          if File.exist?(file_name)
            deleted_file = PhotoUtils.move_file file_name, delete_directory, trash_directory
            total_deleted_files += 1
            puts "Moving: #{file_name} to #{deleted_file}" if verbose

            live_photo_mov_file = PhotoUtils.update_extension(file_name, 'mov')

            if File.exist?(live_photo_mov_file)
              deleted_file = PhotoUtils.move_file live_photo_mov_file, delete_directory, trash_directory
              total_deleted_associated_mov_files += 1
              puts "Moving: #{live_photo_mov_file} to #{deleted_file}" if verbose
            end
          else
            total_skipped_files += 1
            puts "Skipping: #{file_name} - does not exist" if verbose
          end

          break
        end
      end
    end

    puts "Deleted (#{total_deleted_files}) duplicate files"
    puts "Deleted (#{total_deleted_associated_mov_files}) .mov files"
    puts "Skipped (#{total_skipped_files}) non existing files"
  end
end
