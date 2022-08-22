module Csvlint
  module FileUrl
    # Convert a path to an absolute file:// uri
    def self.url(path)
      URI.encode_www_form_component(File.expand_path(path).gsub(/^\/*/, "file:///"))
    end

    # Convert an file:// uri to a File
    def self.file(uri)
      if /^file:/.match?(uri.to_s)
        uri = URI.decode_www_form_component(uri)
        uri = uri.gsub(/^file:\/*/, "/")
        File.new(uri)
      else
        uri
      end
    end
  end
end
