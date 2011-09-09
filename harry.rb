# encoding: utf-8
require "rubygems"
require "sinatra"
require "fileutils"
require "fog"
require "json"
require "yaml"
require "redis"

class Build
  attr_accessor :name, :repository, :version, :bundler
  def initialize(name, repository, bundler = true)
    puts "init"
    @name = name
    @repository = repository
    @current_path = File.expand_path(File.dirname(__FILE__))
    @bundler = bundler
    repositories = Hash.new
    repositories = YAML.load_file(@current_path + "/config/repositories.yml") if File.exist?(@current_path + "/config/repositories.yml")
    if repositories[name] == nil
      repositories[name] = {"name" => name, "repository" => repository, "version" => "1"}
      FileUtils.mkdir(@current_path + "/config") unless File.exist?(@current_path + "/config")
      File.open(@current_path + "/config/repositories.yml", 'w' ) do |out|
        YAML.dump(repositories, out)
      end
    end
    @version = repositories[name]["version"]
  end

  def next_version
    return (version.to_i + 1).to_s
  end

  def run
    puts "cloning"
    self.version = next_version
    FileUtils.mkdir("/var/build/#{name}") unless File.exist?("/var/build/#{name}")
    Dir.chdir("/var/build/#{name}")
    clone_shallow = `git clone --depth 1 #{repository} #{version}`
    FileUtils.rm_rf("#{version}/.git")
    puts "bundle in /var/build/#{name}/#{version}"
    Dir.chdir("/var/build/#{name}/#{version}")
    log = `bundle install --deployment --without development test`
    Dir.chdir("/var/build/#{name}")
    puts "archive : /var/build/#{name}/#{name}-#{version}.tar.gz"
    log = `tar -czf /var/build/#{name}/#{name}-#{version}.tar.gz #{version}`
    FileUtils.rm_rf("/var/build/#{name}/#{version}")
  end

  def save
    puts "saving"
    repositories = YAML.load_file(@current_path + "/config/repositories.yml") if File.exist?(@current_path + "/config/repositories.yml")
    repositories[name] = {"name" => name, "repository" => repository, "version" => version}
    FileUtils.mkdir(@current_path + "/config") unless File.exist?(@current_path + "/config")
    File.open(@current_path + "/config/repositories.yml", 'w' ) do |out|
      YAML.dump(repositories, out)
    end
  end

  def upload
    puts "uploading"
    current_path = File.expand_path(File.dirname(__FILE__))
  	config = YAML.load_file(current_path + "/config.yml")
  	rs_dir = "sqshed_apps"
  	storage = Fog::Storage.new(:provider => 'Rackspace', :rackspace_auth_url => config["rackspace_auth_url"], :rackspace_api_key => config["rackspace_api_key"], :rackspace_username => config['rackspace_username'])
    directory = storage.directories.get(rs_dir)
    directory.files.create(:key => "#{name}-#{version}.tar.gz", :body => File.open("/var/build/#{name}/#{name}-#{version}.tar.gz"))
    FileUtils.rm_rf("/var/build/#{name}/#{name}-#{version}.tar.gz") if File.exist?("/var/build/#{name}/#{name}-#{version}.tar.gz")
  end

  def register
    puts "register"
    current_path = File.expand_path(File.dirname(__FILE__))
  	config = YAML.load_file(current_path + "/config.yml")
  	#  {"version" => integer,      # the version number
    #   "name" => string,           # the name of the app
    #   "status" => string,         # starts with "waiting"
    #   "started_at" => datetime,   # the time when the app was added in the queue
    #   "finished_at" => datetime,  # the time when the app was properly deployed
    #   "backoffice" => boolean,     # hoy
    #   "db_string" => "ALREADY_DONE",  # used to pass db string
    #   }
    # }
    status_hash = {"db_string" => "ALREADY_DONE", "version" => version, "name" => name, "status" => "waiting", "started_at" => Time.now.to_s, "finished_at" => "", "backoffice" => "1"}
    redis = Redis.new(:host => config['redis']['host'], :port => config['redis']['port'], :password => config['redis']['password'], :db => config['redis']['db'])
    queue = JSON.parse(redis.get(config['cuddy_token'])) if redis.get(config['cuddy_token'])
    queue ||= Array.new
    queue << status_hash
    redis.set(config['cuddy_token'], queue.to_json)
  end
end

class Harry < Sinatra::Application
	enable :logging
	configure do 
    Log = Logger.new("sinatra.log")
    Log.level  = Logger::INFO 
  end

  get '/' do
    "ready to build ! sir"
  end

  post '/' do
    @current_path = File.expand_path(File.dirname(__FILE__))
  	@config = YAML.load_file(@current_path + "/config.yml")
    token = env['HTTP_TOKEN'] || env['TOKEN']
    if token != @config['token']
      status 403
      return
    end
    build = nil
    if params[:payload]
      push = JSON.parse(params[:payload])
      build = Build.new(push["repository"]["name"], push["repository"]["url"].gsub(/^http/, 'git'), params[:bundler])
    else
      puts "Received #{params[:name]} #{params[:repository]}"
      build = Build.new(params[:name], params[:repository], params[:bundler])
    end
    if (params[:no_rebuild] && (params[:no_rebuild].to_i == 1))
      puts "Only registering"
      fork { build.register unless params[:no_register] }
    else
      puts "Full build"
      fork do
        build.run
        build.save
        build.upload
        build.register unless params[:no_register]
      end
    end
    status 200
  end
end