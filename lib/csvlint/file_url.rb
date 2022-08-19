module Csvlint
  module FileUrl
    # Convert a path to an absolute file:// uri
    def self.url(path)
      URI.encode(File.expand_path(path).gsub(/^\/*/, "file:///"))
    end

    # Convert an file:// uri to a File
    def self.file(uri)
      if uri.start_with?("file:")
        uri = URI.decode(uri)
        uri = uri.gsub(/^file:\/*/, "/")
        File.new(uri)
      else
        uri
      end
    end
  end
end
