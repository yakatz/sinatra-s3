require 'rubygems'
require 'activerecord'

require 'sinatra/base'
require 'openssl'
require 'digest/sha1'
require 'md5'
require 'sinatra/async'
require 'builder'

begin
  require "git"
  puts "-- Git support found, versioning support enabled."
rescue LoadError
  puts "-- Git support not found, versioning support disabled."
end

DEFAULT_PASSWORD = 'pass@word1'
DEFAULT_SECRET = 'OtxrzxIsfpFjA7SwPzILwy8Bw21TLhquhboDYROV'

BUFSIZE = (4 * 1024)
STORAGE_PATH = File.join(File.expand_path(File.dirname(__FILE__)), 'storage') unless defined?(STORAGE_PATH)
RESOURCE_TYPES = %w[acl versioning]
CANNED_ACLS = {
  'private' => 0600,
  'public-read' => 0644,
  'public-read-write' => 0666,
  'authenticated-read' => 0640,
  'authenticated-read-write' => 0660
}
READABLE = 0004
WRITABLE = 0002
READABLE_BY_AUTH = 0040
WRITABLE_BY_AUTH = 0020

POST = %{if(!this.title||confirm(this.title+'?')){var f = document.createElement('form'); this.parentNode.appendChild(f); f.method = 'POST'; f.action = this.href; f.submit();}return false;}

require "#{File.dirname(__FILE__)}/app/models/nested_set"
ActiveRecord::Base.send :include, ActiveRecord::Acts::NestedSet

%w(bit bucket git_bucket slot user file_info).each {|r| require "#{File.dirname(__FILE__)}/app/models/#{r}" }
%w(helpers errors admin base).each {|r| require "#{File.dirname(__FILE__)}/app/#{r}"}

ActiveRecord::Base.logger = Logger.new(STDERR)