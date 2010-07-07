module S3

  def self.config
    @config ||= YAML.load_file("s3.yml")[S3::Application.environment]
  end

  class Application < Sinatra::Base

    enable :static
    set :public, File.join(File.dirname(__FILE__), '..', 'public')
    disable :raise_errors, :show_exceptions
    set :environment, :production

    register Sinatra::Async

    helpers do
      include S3::Helpers
    end

    configure do
      ActiveRecord::Base.establish_connection(S3.config[:db]) 
    end

    before do
      @meta, @amz = {}, {}
      @env.each do |k,v|
	k = k.downcase.gsub('_', '-')
	@amz[$1] = v.strip if k =~ /^http-x-amz-([-\w]+)$/
	@meta[$1] = v if k =~ /^http-x-amz-meta-([-\w]+)$/
      end

      auth, key_s, secret_s = *env['HTTP_AUTHORIZATION'].to_s.match(/^AWS (\w+):(.+)$/)
      date_s = env['HTTP_X_AMZ_DATE'] || env['HTTP_DATE']
      if request.params.has_key?('Signature') and Time.at(request['Expires'].to_i) >= Time.now
	key_s, secret_s, date_s = request['AWSAccessKeyId'], request['Signature'], request['Expires']
      end
      uri = env['PATH_INFO']
      uri += "?" + env['QUERY_STRING'] if RESOURCE_TYPES.include?(env['QUERY_STRING'])
      canonical = [env['REQUEST_METHOD'], env['HTTP_CONTENT_MD5'], env['CONTENT_TYPE'],
	date_s, uri]
      @amz.sort.each do |k, v|
	canonical[-1,0] = "x-amz-#{k}:#{v}"
      end
      @user = User.find_by_key key_s
      if (@user and secret_s != hmac_sha1(@user.secret, canonical.map{|v|v.to_s.strip} * "\n")) || (@user and @user.deleted == 1)
	raise BadAuthentication
      end
    end

    aget '/' do
      only_authorized
      buckets = Bucket.user_buckets(@user.id)

      xml do |x|
	x.ListAllMyBucketsResult :xmlns => "http://s3.amazonaws.com/doc/2006-03-01/" do
	  x.Owner do
	    x.ID @user.key
	    x.DisplayName @user.login
	  end
	  x.Buckets do
	    buckets.each do |b|
	      x.Bucket do
		x.Name b.name
		x.CreationDate b.created_at.getgm.iso8601
	      end
	    end
	  end
	end
      end
    end


    # get bucket
    aget %r{^/([^\/]+)/?$} do
      bucket = Bucket.find_root(params[:captures].first)
      acl_response_for(bucket) and return if params.has_key?('acl')
      versioning_response_for(bucket) and return if params.has_key?('versioning')
      only_can_read bucket

      params['prefix'] ||= ''
      params['marker'] ||= ''

      query = bucket.items(params['marker'],params['prefix'])
      slot_count = query.count
      contents = query.find(:all, :include => :owner, 
			    :limit => params['max-keys'].blank? ? 1000 : params['max-keys'])

      if params['delimiter']
	# Build a hash of { :prefix => content_key }. The prefix will not include the supplied params['prefix'].
	prefixes = contents.inject({}) do |hash, c|
	  prefix = get_prefix(c).to_sym
	  hash[prefix] = [] unless hash[prefix]
	  hash[prefix] << c.name
	  hash
	end

	# The common prefixes are those with more than one element
	common_prefixes = prefixes.inject([]) do |array, prefix|
	  array << prefix[0].to_s if prefix[1].size > 1
	  array
	end

	# The contents are everything that doesn't have a common prefix
	contents = contents.reject do |c|
	  common_prefixes.include? get_prefix(c)
	end
      end

      xml do |x|
	x.ListBucketResult :xmlns => "http://s3.amazonaws.com/doc/2006-03-01/" do
	  x.Name bucket.name
	  x.Prefix params['prefix']
	  x.Marker params['marker']
	  x.Delimiter params['delimiter'] if params['delimiter']
	  x.MaxKeys params['max-keys'].blank? ? 1000 : params['max-keys']
	  x.IsTruncated slot_count > contents.length
	  contents.each do |c|
	    x.Contents do
	      x.Key c.name
	      x.LastModified c.updated_at.getgm.iso8601
	      x.ETag c.etag
	      x.Size c.obj.size
	      x.StorageClass "STANDARD"
	      x.Owner do
		x.ID c.owner.key
		x.DisplayName c.owner.login
	      end
	    end
	  end
	  unless common_prefixes.nil?
	    common_prefixes.each do |p|
	      x.CommonPrefixes do
		x.Prefix p
	      end
	    end
	  end
	end
      end
    end

    # create bucket
    aput %r{^/([^\/]+)/?$} do
      begin
	only_authorized
	bucket = Bucket.find_root(params[:captures].first)

	#raise BucketAlreadyExists unless bucket.nil?

	only_owner_of bucket
	bucket.grant(requested_acl(bucket))
	headers 'Location' => env['PATH_INFO'], 'Content-Length' => 0.to_s
	body ""
      rescue NoSuchBucket
	Bucket.create(:name => params[:captures].first, :owner_id => @user.id).grant(requested_acl)
	headers 'Location' => env['PATH_INFO'], 'Content-Length' => 0.to_s
	body ""
      end
    end

    # delete bucket
    adelete %r{^/([^\/]+)/?$} do
      bucket = Bucket.find_root(params[:captures].first)
      only_owner_of bucket

      raise BucketNotEmpty if Slot.count(:conditions => ['deleted = 0 AND parent_id = ?', bucket.id]) > 0

      bucket.destroy
      status 204
      body ""
    end

    # get slot
    aget %r{^/(.+?)/(.+)$} do
      bucket = Bucket.find_root(params[:captures].first)

      h = {}
      if params.has_key?('version-id')
	@revision = bucket.git_repository.gcommit(params['version-id'])
	h.merge!({ 'x-amz-version-id' => @revision.sha })
	@slot = bucket.find_slot(params[:captures].last)
	@revision_file = @revision.gtree.blobs[File.basename(@slot.fullpath)].contents { |f| f.read }
      else
	@slot = bucket.find_slot(params[:captures].last)
	git_object = @slot.git_object
	h.merge!({ 'x-amz-version-id' => git_object.objectish }) if git_object
      end

      if params.has_key? 'acl'
	only_can_read_acp @slot
      else
	only_can_read @slot
      end

      etag = @slot.etag
      since = Time.httpdate(env['HTTP_IF_MODIFIED_SINCE']) rescue nil
      raise NotModified if since and @slot.updated_at <= since
      since = Time.httpdate(env['HTTP_IF_UNMODIFIED_SINCE']) rescue nil
      raise PreconditionFailed if since and @slot.updated_at > since
      raise PreconditionFailed if env['HTTP_IF_MATCH'] and etag != env['HTTP_IF_MATCH']
      raise NotModified if env['HTTP_IF_NONE_MATCH'] and etag == env['HTTP_IF_NONE_MATCH']

      @slot.meta.each { |k, v|
	h.merge!({ "x-amz-meta-#{k}" => v })
      }

      if @slot.obj.is_a? FileInfo
	h.merge!({ 'Content-Disposition' => @slot.obj.disposition, 'Content-Length' => (@revision_file.nil? ? 
	  @slot.obj.size : @revision_file.length).to_s, 'Content-Type' => @slot.obj.mime_type })
      end
      h['Content-Type'] ||= 'binary/octet-stream'
      h.merge!('ETag' => etag, 'Last-Modified' => @slot.updated_at.httpdate) if @revision_file.nil?

      acl_response_for(@slot) and return if params.has_key?('acl')

      if params.has_key?('version-id')
        headers h
	body @revision_file
      elsif @slot.obj.kind_of?(FileInfo) && env['HTTP_RANGE'] =~ /^bytes=(\d+)?-(\d+)?$/ # yay, parse basic ranges
      elsif env['HTTP_RANGE']  # ugh, parse ranges
	raise NotImplemented
      else
	case @slot.obj
	when FileInfo
	  headers h
	  body open(File.join(STORAGE_PATH, @slot.obj.path))
	else
	  headers h
	  body @slot.obj
	end
      end
    end

    # create slot
    aput %r{^/(.+?)/(.+)$} do
      bucket = Bucket.find_root(params[:captures].first)
      only_can_write bucket

      raise MissingContentLength unless env['CONTENT_LENGTH']

      if params.has_key?('acl')
	slot = bucket.find_slot(oid)
	slot.grant(requested_acl(slot))
	headers 'ETag' => slot.etag, 'Content-Length' => 0.to_s
	body ""
      elsif env['HTTP_X_AMZ_COPY_SOURCE'].to_s =~ /\/(.+?)\/(.+)/
	source_bucket_name = $1
	source_oid = $2

	source_slot = Bucket.find_root(source_bucket_name).find_slot(source_oid)
	@meta = source_slot.meta
	only_can_read source_slot

	temp_path = File.join(STORAGE_PATH, source_slot.obj.path)
	fileinfo = source_slot.obj
	fileinfo.path = File.join(params[:captures].first, rand(10000).to_s(36) + '_' + File.basename(temp_path))
	fileinfo.path.succ! while File.exists?(File.join(STORAGE_PATH, fileinfo.path))
	file_path = File.join(STORAGE_PATH,fileinfo.path)
      else
	temp_path = env['rack.input'][:path] rescue nil
	readlen = 0
	md5 = MD5.new

	Tempfile.open(File.basename(params[:captures].last)) do |tmpf|
	  temp_path ||= tmpf.path
	  tmpf.binmode
	  while part = env['rack.input'].read(BUFSIZE)
	    readlen += part.size
	    md5 << part
	    tmpf << part unless env['rack.input'].is_a?(Tempfile)
	  end
	end

	fileinfo = FileInfo.new
	fileinfo.mime_type = env['CONTENT_TYPE'] || "binary/octet-stream"
	fileinfo.disposition = env['CONTENT_DISPOSITION']
	fileinfo.size = readlen
	fileinfo.md5 = Base64.encode64(md5.digest).strip
	fileinfo.etag = '"' + md5.hexdigest + '"'

	raise IncompleteBody if env['CONTENT_LENGTH'].to_i != readlen
	if @env['HTTP_CONTENT_MD5']
	  b64cs = /[0-9a-zA-Z+\/]/
	    re = /
	    ^
	  (?:#{b64cs}{4})*       # any four legal chars
	    (?:#{b64cs}{2}        # right-padded by up to two =s
	     (?:#{b64cs}|=){2})?
	     $
	  /ox

	  raise InvalidDigest unless @env['HTTP_CONTENT_MD5'] =~ re
	  raise BadDigest unless fileinfo.md5 == @env['HTTP_CONTENT_MD5']
	end
      end

      mdata = {}

      slot = nil
      meta = @meta.nil? || @meta.empty? ? {} : {}.merge(@meta)
      owner_id = @user ? @user.id : bucket.owner_id

      begin
	slot = bucket.find_slot(params[:captures].last)
	if source_slot.nil?
	  fileinfo.path = slot.obj.path
	  file_path = File.join(STORAGE_PATH,fileinfo.path)
	  FileUtils.mv(temp_path, file_path,{ :force => true })
	else
	  FileUtils.cp(temp_path, file_path)
	end
	slot.update_attributes(:owner_id => owner_id, :meta => meta, :obj => fileinfo)
      rescue NoSuchKey
	if source_slot.nil?
	  fileinfo.path = File.join(params[:captures].first, rand(10000).to_s(36) + '_' + File.basename(temp_path))
	  fileinfo.path.succ! while File.exists?(File.join(STORAGE_PATH, fileinfo.path))
	  file_path = File.join(STORAGE_PATH,fileinfo.path)
	  puts file_path
	  FileUtils.mkdir_p(File.dirname(file_path))
	  FileUtils.mv(temp_path, file_path)
	else
	  FileUtils.cp(temp_path, file_path)
	end
	slot = Slot.create(:name => params[:captures].last, :owner_id => owner_id, :meta => meta, :obj => fileinfo)
	bucket.add_child(slot)
      end
      slot.grant(requested_acl(slot))

      h = { 'Content-Length' => 0.to_s, 'ETag' => slot.etag }
      if slot.versioning_enabled?
	begin
	  slot.git_repository.add(File.basename(fileinfo.path))
	  tmp = slot.git_repository.commit("Added #{slot.name} to the Git repository.")
	  slot.git_update
	  h.merge!({ 'x-amz-version-id' => slot.git_object.objectish })
	rescue Git::GitExecuteError => error_message
	  puts "[#{Time.now}] GIT: #{error_message}"
	end
      end
      headers h
      body ""
    end

    # delete slot
    adelete %r{^/(.+?)/(.+)$} do
      bucket = Bucket.find_root(params[:captures].first)
      only_can_write bucket

      begin
	@slot = bucket.find_slot(params[:captures].last)
	if @slot.versioning_enabled?
	  begin
	    @slot.git_repository.remove(File.basename(@slot.obj.path))
	    @slot.git_repository.commit("Removed #{@slot.name} from the Git repository.")
	    @slot.git_update
	  rescue Git::GitExecuteError => error_message
	    puts "[#{Time.now}] GIT: #{error_message}"
	  end
	end

	@slot.destroy
	status 204
	body ""
      rescue NoSuchKey
	status 204
	body ""
      end
    end

    error do
      error = Builder::XmlMarkup.new
      error.instruct! :xml, :version=>"1.0", :encoding=>"UTF-8"

      error.Error do
	error.Code request.env['sinatra.error'].code
	error.Message request.env['sinatra.error'].message
	error.Resource env['PATH_INFO']
	error.RequestId Time.now.to_i
      end

      status request.env['sinatra.error'].status.nil? ? 500 : request.env['sinatra.error'].status
      content_type 'application/xml'
      error.target!
    end

  end

end