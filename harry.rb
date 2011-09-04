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
    @name = name
    @repository = repository
    @current_path = File.expand_path(File.dirname(__FILE__))
    @bundler = bundler
    repositories = YAML.load_file(@current_path + "/repositories.yml")
    if repositories[name] == nil
      repositories[name] = {"name" => name, "repository" => repository, "version" => "0.1"}
      File.open(@current_path + "/repositories.yml", 'w' ) do |out|
        YAML.dump(repositories, out)
      end
    end
    @version = repositories[name]["version"]
  end

  def next_version
    version_n = version.split('.')
    splits = version_n.size
    splits.last = (splits.last.to_i + 1).to_s
    return splits.join('.')
  end

  def run
    self.version = next_version
    FileUtils.mkdir("/var/build/#{name}/#{name}") unless File.exist?("/var/build/#{name}/#{name}")
    Dir.chdir("/var/build/#{name}/#{name}")
    clone_shallow = `git clone --depth 1 #{repository} #{version}`
    FileUtils.rm_rf("#{version}/.git")
    Dir.chdir("/var/build/#{name}/#{name}/#{version}")
    `bundle install --deployment --without development test`
    Dir.chdir("/var/build/#{name}")
    `tar -czf /var/build/#{name}/#{name}-#{version}.tar.gz #{name}`
    FileUtils.rm_rf("/var/build/#{name}/#{name}/#{version}")
  end

  def save
    repositories = YAML.load_file(@current_path + "/repositories.yml")
    repositories[name] = {"name" => name, "repository" => repository, "version" => version}
    File.open(@current_path + "/config/repositories.yml", 'w' ) do |out|
      YAML.dump(repositories, out)
    end
  end

  def upload
    current_path = File.expand_path(File.dirname(__FILE__))
  	config = YAML.load_file(current_path + "/config.yml")
  	rs_dir = "sqshed_apps"
  	storage = Fog::Storage.new(:provider => 'Rackspace', :rackspace_auth_url => config["rackspace_auth_url"], :rackspace_api_key => config["rackspace_api_key"], :rackspace_username => config['rackspace_username'])
    directory = storage.directories.get(rs_dir)
    directory.files.create(:key => "#{img}", :body => File.open("/var/build/#{name}/#{name}-#{version}.tar.gz"))
    FileUtils.rm_rf("/var/build/#{name}/#{name}-#{version}.tar.gz") if File.exist?("/var/build/#{name}/#{name}-#{version}.tar.gz")
  end

  def register
    current_path = File.expand_path(File.dirname(__FILE__))
  	config = YAML.load_file(current_path + "/config.yml")
  	#  {"version" => integer,      # the version number
    #   "name" => string,           # the name of the app
    #   "status" => string,         # starts with "waiting"
    #   "started_at" => datetime,   # the time when the app was added in the queue
    #   "finished_at" => datetime,  # the time when the app was properly deployed
    #   "backoffice" => boolean     # hoy
    #   "config" => { "unicorn" => { "workers" => integer },
    #     "db" => {"hostname" => string, "database" => string, "username" => string, "token" => string}
    #   }
    # }
    status_hash = {"version" => version, "name" => name, "status" => "waiting", "started_at" => Time.now, "finished_at" => "", "backoffice" => true}
    redis = Redis.new(:host => config['redis']['host'], :port => config['redis']['port'], :password => config['redis']['password'], :db => config['redis']['database'])
    redis.set(config['cuddy_token'], status_hash)
  end
end

class Harry < Sinatra::Application
  @current_path = File.expand_path(File.dirname(__FILE__))
	@config = YAML.load_file(@current_path + "/config.yml")

  get '/' do
    "ready to build ! sir"
  end

  post '/' do
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
      build = Build.new(params[:name], params[:url], params[:bundler])
    end
    fork do
      build.run
      build.save
      build.upload
      build.register
    end
    status 200
  end
end