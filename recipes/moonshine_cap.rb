set :branch, 'master'
set :scm, :git
set :git_shallow_clone, 1
set :git_enable_submodules, 1
ssh_options[:paranoid] = false
ssh_options[:forward_agent] = true
default_run_options[:pty] = true

#load the moonshine configuration into
require 'yaml'
begin
  hash = YAML.load_file(File.join((ENV['RAILS_ROOT'] || Dir.pwd), 'config', 'moonshine.yml'))
  hash.each do |key, value|
    set(key.to_sym, value)
  end
rescue Exception
  puts "To use Capistrano with Moonshine, please run 'ruby script/generate moonshine',"
  puts "edit config/moonshine.yml, then re-run capistrano."
  exit(1)
end

namespace :moonshine do

  desc <<-DESC
  Bootstrap a barebones Ubuntu system with Git, Ruby, RubyGems, and Moonshine
  dependencies. Called by deploy:setup.
  DESC
  task :bootstrap do
    #copy the bootstrap script to the server to install Ruby, RubyGems, ShadowPuppet
    put(File.read(File.join(File.dirname(__FILE__), '..', 'bin', 'bootstrap.sh')),"/tmp/bootstrap.sh")
    sudo 'chmod a+x /tmp/bootstrap.sh'
    sudo '/tmp/bootstrap.sh'
    sudo 'rm /tmp/bootstrap.sh'
    # copy moonshine_setup_manifest.rb to the server
    put(File.read(File.join(File.dirname(__FILE__), '..', 'lib', 'moonshine_setup_manifest.rb')),"/tmp/moonshine_setup_manifest.rb")
    begin
      config = YAML.load_file(File.join(Dir.pwd, 'config', 'moonshine.yml'))
      put(YAML.dump(config),"/tmp/moonshine.yml")
    rescue
      puts "Please run 'ruby script/generate moonshine' and configure config/moonshine.yml first"
      exit(0)
    end
    sudo "shadow_puppet /tmp/moonshine_setup_manifest.rb"
    sudo 'rm /tmp/moonshine_setup_manifest.rb'
    sudo 'rm /tmp/moonshine.yml'
  end

  desc 'Apply the Moonshine manifest for this application'
  task :apply do
    sudo "RAILS_ROOT=#{current_release} RAILS_ENV=#{fetch(:rails_env, 'production')} shadow_puppet #{current_release}/app/manifests/#{fetch(:moonshine_manifest, 'application_manifest')}.rb"
  end

  after 'deploy:update_code' do
    local_config.upload
    local_config.symlink
    apply if fetch(:moonshine_apply, true) == true
  end

  namespace :app do

    desc "remotely console"
    task :console, :roles => :app, :except => {:no_symlink => true} do
      input = ''
      run "cd #{current_release} && ./script/console #{fetch(:rails_env, 'production')}" do |channel, stream, data|
        next if data.chomp == input.chomp || data.chomp == ''
        print data
        channel.send_data(input = $stdin.gets) if data =~ /^(>|\?)>/
      end
    end

    desc "tail production log files"
    task :log, :roles => :app, :except => {:no_symlink => true} do
      run "tail -f #{shared_path}/log/production.log" do |channel, stream, data|
        puts "#{data}"
        break if stream == :err
      end
    end

    desc "tail apache error log"
    task :error_log, :roles => :app, :except => {:no_symlink => true} do
      run "/var/log/apache2/error.log" do |channel, stream, data|
        puts "#{data}"
        break if stream == :err
      end
    end

    desc "tail apache access log"
    task :access_log, :roles => :app, :except => {:no_symlink => true} do
      run "/var/log/apache2/access.log" do |channel, stream, data|
        puts "#{data}"
        break if stream == :err
      end
    end
  end

  task :update_and_console do
    set :moonshine_apply, false
    deploy.update_code
    app.console
  end

  task :update_and_rake do
    set :moonshine_apply, false
    deploy.update_code
    run "cd #{current_release} && RAILS_ENV=#{fetch(:rails_env, 'production')} rake --trace environment"
  end

  namespace :local_config do
    
    desc <<-DESC
    Uploads local configuration files to the application's shared directory for
    later symlinking (if necessary). Called if local_config is set.
    DESC
    task :upload do
      fetch(:local_config,[]).each do |file|
        filename = File.split(file).last
        if File.exist?( file )
          put(File.read( file ),"#{shared_path}/#{filename}")
        end
      end
    end
    
    desc <<-DESC
    Symlinks uploaded local configurations into the release directory.
    DESC
    task :symlink do
      fetch(:local_config,[]).each do |file|
        filename = File.split(file).last
        run "ls #{current_release}/#{file} 2> /dev/null || ln -nfs #{shared_path}/#{filename} #{current_release}/#{file}"
      end
    end
    
  end

end
namespace :deploy do
  desc "Restart the Passenger processes on the app server by touching tmp/restart.txt."
  task :restart, :roles => :app, :except => { :no_release => true } do
    run "touch #{current_path}/tmp/restart.txt"
  end

  [:start, :stop].each do |t|
    desc "#{t} task is a no-op with Passenger"
    task t, :roles => :app do ; end
  end

  desc <<-DESC
    Prepares one or more servers for deployment. Before you can use any \
    of the Capistrano deployment tasks with your project, you will need to \
    make sure all of your servers have been prepared with `cap deploy:setup'. When \
    you add a new server to your cluster, you can easily run the setup task \
    on just that server by specifying the HOSTS environment variable:
 
      $ cap HOSTS=new.server.com deploy:setup
 
    It is safe to run this task on servers that have already been set up; it \
    will not destroy any deployed revisions or data.
  DESC
  task :setup, :except => { :no_release => true } do
    moonshine.bootstrap
  end
end