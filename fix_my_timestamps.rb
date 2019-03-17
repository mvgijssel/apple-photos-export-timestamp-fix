#!/usr/bin/env ruby

require 'mini_exiftool'

if ARGV.length != 3
  puts "Please provide three arguments: `fix_my_timestamps src/ dest/ library`"
  exit 1
end

source = ARGV[0]
dest = ARGV[1]
library = ARGV[2]

photo = MiniExiftool.new('images/IMG_7314.JPG')
photo.filemodifydate = ""
