require "addressable"

module Csvlint
  module FileUrl
    # Convert a path to an absolute file:// uri
    def self.url(path)
      Addressable::URI.convert_path(File.expand_path(path)).to_s
    end

    # Convert an file:// uri to a File
    def self.file(uri)
      if /^file:/.match?(uri.to_s)
        uri = Addressable::URI.unencode(uri)
        uri = uri.gsub(/^file:\/*/, "/")
        File.new(uri)
      else
        uri
      end
    end
  end
end
