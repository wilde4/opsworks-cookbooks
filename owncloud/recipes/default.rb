#
# Cookbook Name:: owncloud
# Recipe:: default
#
# Copyright 2013, Onddo Labs, Sl.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#


#==============================================================================
# Download and extract ownCloud
#==============================================================================

directory node['owncloud']['www_dir']

unless node['owncloud']['deploy_from_git']
  basename = ::File.basename(node['owncloud']['download_url'])
  local_file = ::File.join(Chef::Config[:file_cache_path], basename)

  # Prior to Chef 11.6, remote_file does not support conditional get
  # so we do a HEAD http_request to mimic it
  http_request 'HEAD owncloud' do
    message ''
    url node['owncloud']['download_url']
    if Gem::Version.new(Chef::VERSION) < Gem::Version.new('11.6.0')
      action :head
    else
      action :nothing
    end
    if File.exists?(local_file)
      headers 'If-Modified-Since' => File.mtime(local_file).httpdate
    end
    notifies :create, 'remote_file[download owncloud]', :immediately
  end

  remote_file 'download owncloud' do
    source node['owncloud']['download_url']
    path local_file
    if Gem::Version.new(Chef::VERSION) < Gem::Version.new('11.6.0')
      action :nothing
    else
      action :create
    end
    notifies :run, 'bash[extract owncloud]', :immediately
  end

  bash 'extract owncloud' do
    code <<-EOF
      # remove previous installation if any
      if [ -d ./owncloud ]
      then
        pushd ./owncloud >/dev/null
        ls | grep -v 'data\\|config' | xargs rm -r
        popd >/dev/null
      fi
      # extract tar file
      tar xfj '#{local_file}' --no-same-owner
    EOF
    cwd node['owncloud']['www_dir']
    action :nothing
  end
else
  if node['owncloud']['git_ref']
    git_ref = node['owncloud']['git_ref']
  elsif node['owncloud']['version'].eql?('latest')
    git_ref = 'master'
  else
    git_ref = "v#{node['owncloud']['version']}"
  end

  git 'clone owncloud' do
    destination node['owncloud']['dir']
    repository node['owncloud']['git_repo']
    reference git_ref
    enable_submodules true
    action :sync
  end
end

#==============================================================================
# Set up webserver
#==============================================================================

# Get the webserver used
web_server = node['owncloud']['web_server']

include_recipe 'owncloud::_nginx'
web_services = [ 'nginx' ]
# web_services = [ 'nginx', 'php-fpm' ]

#==============================================================================
# Initialize configuration file and install ownCloud
#==============================================================================

# create required directories
[
  ::File.join(node['owncloud']['dir'], 'apps'),
  ::File.join(node['owncloud']['dir'], 'config'),
  node['owncloud']['data_dir']
].each do |dir|
  directory dir do
    owner node[web_server]['user']
    group node[web_server]['group']
    mode 00750
    action :create
  end
end

# create autoconfig.php for the installation
template 'autoconfig.php' do
  path ::File.join(node['owncloud']['dir'], 'config', 'autoconfig.php')
  source 'autoconfig.php.erb'
  owner node[web_server]['user']
  group node[web_server]['group']
  mode 00640
  variables(
    :dbtype => node['owncloud']['config']['dbtype'],
    :dbname => node['owncloud']['config']['dbname'],
    :dbuser => node['owncloud']['config']['dbuser'],
    :dbpass => node['owncloud']['config']['dbpassword'],
    :dbhost => node['owncloud']['config']['dbhost'],
    :dbprefix => node['owncloud']['config']['dbtableprefix'],
    :admin_user => node['owncloud']['admin']['user'],
    :admin_pass => node['owncloud']['admin']['pass'],
    :data_dir => node['owncloud']['data_dir']
  )
  not_if { ::File.exists?(::File.join(node['owncloud']['dir'], 'config', 'config.php')) }

  web_services.each do |web_service|
    notifies :restart, "service[#{web_service}]", :immediately
  end
  notifies :get, 'http_request[run setup]', :immediately
end

# install ownCloud
http_request 'run setup' do
  url 'http://localhost/'
  headers({ 'Host' => node['owncloud']['server_name'] })
  message ''
  action :nothing
end

# Apply the configuration on attributes to config.php
ruby_block 'apply config' do
  block do
    config_file = ::File.join(node['owncloud']['dir'], 'config', 'config.php')
    config = OwnCloud::Config.new(config_file)
    config.merge(node['owncloud']['config'])
    config.write
    unless Chef::Config[:solo]
      # store important options that where generated automatically by the setup
      node.set_unless['owncloud']['config']['passwordsalt'] = config['passwordsalt']
      node.set_unless['owncloud']['config']['instanceid'] = config['instanceid']
      node.save
    end
  end
end

#==============================================================================
# Enable cron for background jobs
#==============================================================================

if node['owncloud']['cron']['enabled'] == true
  cron 'owncloud cron' do
    user node[web_server]['user']
    minute node['owncloud']['cron']['min']
    hour node['owncloud']['cron']['hour']
    day node['owncloud']['cron']['day']
    month node['owncloud']['cron']['month']
    weekday node['owncloud']['cron']['weekday']
    command "php -f '#{node['owncloud']['dir']}/cron.php' >> '#{node['owncloud']['data_dir']}/cron.log' 2>&1"
  end
else
  cron 'owncloud cron' do
    user node[web_server]['user']
    command "php -f '#{node['owncloud']['dir']}/cron.php' >> '#{node['owncloud']['data_dir']}/cron.log' 2>&1"
    action :delete
  end
end
