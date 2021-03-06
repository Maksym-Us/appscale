#!/usr/bin/ruby -w


require 'fileutils'


$:.unshift File.join(File.dirname(__FILE__))
require 'app_dashboard'
require 'blobstore'
require 'custom_exceptions'
require 'datastore_server'
require 'helperfunctions'
require 'monit_interface'
require 'user_app_client'


# A module to wrap all the interactions with the nginx web server
# Google App Engine applications can request that certain files should be
# hosted statically, so we use the nginx web server for this. It is the
# first server that a user hits, and forwards non-static file requests to
# haproxy, which then load balances requests to AppServers. This module
# configures and deploys nginx within AppScale.
module Nginx

  CHANNELSERVER_PORT = 5280

  CONFIG_EXTENSION = "conf"

  # The path on the local filesystem where the nginx binary can be found.
  NGINX_BIN = "/usr/sbin/nginx"

  # Nginx AppScale log directory.
  NGINX_LOG_PATH = "/var/log/nginx"

  # Nginx top configuration directory.
  NGINX_PATH = "/etc/nginx"

  MAIN_CONFIG_FILE = File.join(NGINX_PATH, "nginx.#{CONFIG_EXTENSION}")

  # Nginx sites-enabled path.
  SITES_ENABLED_PATH = File.join(NGINX_PATH, "sites-enabled")

  # These ports are the one visible from outside, ie the ones that we
  # attach to running applications. Default is to have a maximum of 21
  # applications (8080-8100).
  START_PORT = 8080
  END_PORT = 8100

  # This is the start port of SSL connections to applications. Where an
  # app would have the set of ports (8080, 3700), (8081, 3701), and so on.
  SSL_PORT_OFFSET = 3700

  def self.start()
    # Nginx runs both a 'master process' and one or more 'worker process'es, so
    # when we have monit watch it, as long as one of those is running, nginx is
    # still running and shouldn't be restarted.
    service_bin = `which service`.chomp
    start_cmd = "#{service_bin} nginx start"
    stop_cmd = "#{service_bin} nginx stop"
    pidfile = '/var/run/nginx.pid'
    MonitInterface.start_daemon(:nginx, start_cmd, stop_cmd, pidfile)
  end

  def self.stop()
    MonitInterface.stop(:nginx, false)
  end

  # Kills nginx if there was a failure when trying to start/reload.
  #
  def self.cleanup_failed_nginx()
    Djinn.log_error("****Killing nginx because there was a FATAL error****")
    `ps aux | grep nginx | grep worker | awk {'print $2'} | xargs kill -9`
  end

  def self.reload()
    Djinn.log_info("Reloading nginx service.")
    HelperFunctions.shell('service nginx reload')
    if $?.to_i != 0
      cleanup_failed_nginx()
    end
  end

  def self.is_running?()
    output = MonitInterface.is_running?(:nginx)
    Djinn.log_debug("Checking if nginx is already monitored: #{output}")
    return output
  end

  # The port that nginx will be listen on for the given app number
  def self.app_listen_port(app_number)
    START_PORT + app_number
  end

  def self.get_ssl_port_for_app(http_port)
    http_port - SSL_PORT_OFFSET
  end

  # Return true if the configuration is good, false o.w.
  def self.check_config()
    HelperFunctions.shell("#{NGINX_BIN} -t -c #{MAIN_CONFIG_FILE}")
    return ($?.to_i == 0)
  end

  # Creates a Nginx config file for the provided app name on the load balancer.
  # Returns:
  #   boolean: indicates if the nginx configuration has been written.
  def self.write_fullproxy_app_config(app_name, http_port, https_port,
    my_public_ip, my_private_ip, proxy_port, static_handlers, login_ip,
    language)

    parsing_log = "Writing proxy for app #{app_name} with language #{language}.\n"

    secure_handlers = HelperFunctions.get_secure_handlers(app_name)
    parsing_log += "Secure handlers: #{secure_handlers}.\n"
    always_secure_locations = secure_handlers[:always].map { |handler|
      HelperFunctions.generate_secure_location_config(handler, https_port)
    }.join
    never_secure_locations = secure_handlers[:never].map { |handler|
      HelperFunctions.generate_secure_location_config(handler, http_port)
    }.join

    secure_static_handlers = []
    non_secure_static_handlers = []
    static_handlers.map { |handler|
      if handler["secure"] == "always"
        secure_static_handlers << handler
      elsif handler["secure"] == "never"
        non_secure_static_handlers << handler
      else
        secure_static_handlers << handler
        non_secure_static_handlers << handler
      end
    }

    secure_static_locations = secure_static_handlers.map { |handler|
      HelperFunctions.generate_location_config(handler)
    }.join
    non_secure_static_locations = non_secure_static_handlers.map { |handler|
      HelperFunctions.generate_location_config(handler)
    }.join

    # Java application needs a redirection for the blobstore.
    java_blobstore_redirection = ""
    if language == "java"
      java_blobstore_redirection = <<JAVA_BLOBSTORE_REDIRECTION
location ~ /_ah/upload/.* {
      proxy_pass            http://gae_#{app_name}_blobstore;
      proxy_connect_timeout 600;
      proxy_read_timeout    600;
      client_body_timeout   600;
      client_max_body_size  2G;
    }
JAVA_BLOBSTORE_REDIRECTION
    end

    if never_secure_locations.include?('location / {')
      secure_default_location = ''
    else
      secure_default_location = <<DEFAULT_CONFIG
location / {
      proxy_set_header      X-Real-IP $remote_addr;
      proxy_set_header      X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header      X-Forwarded-Proto $scheme;
      proxy_set_header      X-Forwarded-Ssl $ssl;
      proxy_set_header      Host $http_host;
      proxy_redirect        off;
      proxy_pass            http://gae_ssl_#{app_name};
      proxy_connect_timeout 600;
      proxy_read_timeout    600;
      client_body_timeout   600;
      client_max_body_size  2G;
    }
DEFAULT_CONFIG
    end

    if always_secure_locations.include?('location / {')
      non_secure_default_location = ''
    else
      non_secure_default_location = <<DEFAULT_CONFIG
location / {
      proxy_set_header      X-Real-IP $remote_addr;
      proxy_set_header      X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header      X-Forwarded-Proto $scheme;
      proxy_set_header      X-Forwarded-Ssl $ssl;
      proxy_set_header      Host $http_host;
      proxy_redirect        off;
      proxy_pass            http://gae_#{app_name};
      proxy_connect_timeout 600;
      proxy_read_timeout    600;
      client_body_timeout   600;
      client_max_body_size  2G;
    }
DEFAULT_CONFIG
    end

    config = <<CONFIG
# Any requests that aren't static files get sent to haproxy
upstream gae_#{app_name} {
    server #{my_private_ip}:#{proxy_port};
}

upstream gae_ssl_#{app_name} {
    server #{my_private_ip}:#{proxy_port};
}

upstream gae_#{app_name}_blobstore {
    server #{my_private_ip}:#{BlobServer::HAPROXY_PORT};
}

map $scheme $ssl {
    default off;
    https on;
}

server {
    listen      #{http_port};
    server_name #{my_public_ip}-#{app_name};

    #root #{HelperFunctions::APPLICATIONS_DIR}/#{app_name}/app;
    # Uncomment these lines to enable logging, and comment out the following two
    #access_log #{NGINX_LOG_PATH}/appscale-#{app_name}.access.log upstream;
    #error_log  /dev/null crit;
    access_log  off;
    error_log   #{NGINX_LOG_PATH}/appscale-#{app_name}.error.log;

    ignore_invalid_headers off;
    rewrite_log off;
    error_page 404 = /404.html;
    set $cache_dir #{HelperFunctions::APPLICATIONS_DIR}/#{app_name}/cache;

    # If they come here using HTTPS, bounce them to the correct scheme.
    error_page 400 http://$host:$server_port$request_uri;

    #{always_secure_locations}
    #{non_secure_static_locations}
    #{non_secure_default_location}

    #{java_blobstore_redirection}

    location /reserved-channel-appscale-path {
      proxy_buffering    off;
      tcp_nodelay        on;
      keepalive_timeout  600;
      proxy_pass         http://#{login_ip}:#{CHANNELSERVER_PORT}/http-bind;
      proxy_read_timeout 120;
    }
}

server {
    listen      #{https_port};
    server_name #{my_public_ip}-#{app_name}-ssl;
    ssl on;
    ssl_protocols TLSv1 TLSv1.1 TLSv1.2;  # don't use SSLv3 ref: POODLE
    ssl_certificate     #{NGINX_PATH}/mycert.pem;
    ssl_certificate_key #{NGINX_PATH}/mykey.pem;

    # If they come here using HTTP, bounce them to the correct scheme.
    error_page 400 https://$host:$server_port$request_uri;
    error_page 497 https://$host:$server_port$request_uri;

    #root #{HelperFunctions::APPLICATIONS_DIR}/#{app_name}/app;
    # Uncomment these lines to enable logging, and comment out the following two
    #access_log #{NGINX_LOG_PATH}/appscale-#{app_name}.access.log upstream;
    #error_log  /dev/null crit;
    access_log  off;
    error_log   #{NGINX_LOG_PATH}/appscale-#{app_name}.error.log;

    ignore_invalid_headers off;
    rewrite_log off;
    set $cache_dir #{HelperFunctions::APPLICATIONS_DIR}/#{app_name}/cache;

    error_page 404 = /404.html;

    #{never_secure_locations}
    #{secure_static_locations}
    #{secure_default_location}

    #{java_blobstore_redirection}

    location /reserved-channel-appscale-path {
      proxy_buffering    off;
      tcp_nodelay        on;
      keepalive_timeout  600;
      proxy_pass         http://#{login_ip}:#{CHANNELSERVER_PORT}/http-bind;
      proxy_read_timeout 120;
    }
}
CONFIG

    config_path = File.join(SITES_ENABLED_PATH,
                            "appscale-#{app_name}.#{CONFIG_EXTENSION}")

    # Let's reload and overwrite only if something changed.
    current = ""
    current = File.read(config_path) if File.exists?(config_path)
    if current != config
      Djinn.log_debug(parsing_log)
      File.open(config_path, "w+") { |dest_file| dest_file.write(config) }
      reload_nginx(config_path, app_name)
      return true
    end

    Djinn.log_debug("No need to restart nginx: configuration didn't change.")
    return false
  end

  def self.reload_nginx(config_path, app_name)
    if Nginx.check_config()
      Nginx.reload()
      return true
    else
      Djinn.log_error("Unable to load Nginx config for #{app_name}")
      FileUtils.rm_f(config_path)
      return false
    end
  end

  def self.remove_app(app_name)
    config_name = "appscale-#{app_name}.#{CONFIG_EXTENSION}"
    FileUtils.rm_f(File.join(SITES_ENABLED_PATH, config_name))
    Nginx.reload()
  end

  # Removes all the enabled sites
  def self.clear_sites_enabled()
    if File.directory?(SITES_ENABLED_PATH)
      sites = Dir.entries(SITES_ENABLED_PATH)

      # Only remove AppScale-related config files.
      to_remove = []
      sites.each { |site|
        if site.end_with?(CONFIG_EXTENSION) && site.start_with?('appscale-')
          to_remove.push(site)
        end
      }

      full_path_sites = to_remove.map { |site|
        File.join(SITES_ENABLED_PATH, site)
      }
      FileUtils.rm_f full_path_sites
      Nginx.reload()
    end
  end

  # Creates an Nginx configuration file for a service or just adds
  # new location block
  #
  # Args:
  #   service_name: A string specifying the service name.
  #   service_host: A string specifying the location of the service.
  #   service_port: An integer specifying the service port.
  #   nginx_port: An integer specifying the port for Nginx to listen on.
  #   location: A string specifying an Nginx location match.
  def self.add_service_location(service_name, service_host, service_port,
    nginx_port, location='/')
    proxy_pass = "#{service_host}:#{service_port}"
    config_path = File.join(SITES_ENABLED_PATH,
                            "#{service_name}.#{CONFIG_EXTENSION}")
    old_config = File.read(config_path) if File.file?(config_path)

    locations = {}

    if old_config
      # Check if there is no port conflict
      old_nginx_port = old_config.match(/listen (\d+)/m)[1]
      if old_nginx_port != nginx_port.to_s
        msg = "Can't update nginx configs for #{service_name} "\
              "(old nginx port: #{old_nginx_port}, new: #{nginx_port})"
        Djinn.log_error(msg)
        raise AppScaleException.new(msg)
      end

      # Find all specified locations and update it
      regex = /location ([\/\w]+) \{.+?proxy_pass +http?\:\/\/([\d.]+\:\d+)/m
      locations = Hash[old_config.scan(regex)]
    end

    # Ensure new location is associated with a right proxy_pass
    locations[location] = proxy_pass

    config = <<CONFIG
server {
    listen #{nginx_port};

    ssl on;
    ssl_protocols TLSv1 TLSv1.1 TLSv1.2;  # don't use SSLv3 ref: POODLE
    ssl_certificate     #{NGINX_PATH}/mycert.pem;
    ssl_certificate_key #{NGINX_PATH}/mykey.pem;

    #access_log #{NGINX_LOG_PATH}/#{service_name}.access.log upstream;
    #error_log  #{NGINX_LOG_PATH}/#{service_name}.error.log;
    access_log  off;
    error_log   /dev/null crit;

    ignore_invalid_headers off;
    rewrite_log off;

    # If they come here using HTTP, bounce them to the correct scheme.
    error_page 400 https://$host:$server_port$request_uri;
    error_page 497 https://$host:$server_port$request_uri;

    error_page 502 /502.html;

    # Locations:
CONFIG

    locations.each do |location_key, proxy_pass_value|
      location_conf = <<LOCATION
    location #{location_key} {
      proxy_pass            http://#{proxy_pass_value};
      proxy_read_timeout    600;
      client_max_body_size  2G;
    }

LOCATION
      config << location_conf
    end
    config << "}"

    File.write(config_path, config)
    Nginx.reload
  end

  # Set up the folder structure and creates the configuration files necessary for nginx
  def self.initialize_config
    config = <<CONFIG
user www-data;
worker_processes 1;

error_log /var/log/nginx/error.log;
pid       /run/nginx.pid;

events {
    worker_connections 30000;
}

http {
    include       #{NGINX_PATH}/mime.types;
    default_type  application/octet-stream;
    access_log    /var/log/nginx/access.log;

    log_format upstream '$remote_addr - - [$time_local] "$request" status $status '
                        'upstream $upstream_response_time request $request_time '
                        '[for $host via $upstream_addr]';

    sendfile    on;
    #tcp_nopush on;

    keepalive_timeout  600;
    tcp_nodelay        on;
    server_names_hash_bucket_size 128;
    types_hash_max_size           2048;
    gzip on;

    include #{NGINX_PATH}/sites-enabled/*;
}
CONFIG

    HelperFunctions.shell("mkdir -p /var/log/nginx/")
    # Create the sites enabled folder
    unless File.exists? SITES_ENABLED_PATH
      FileUtils.mkdir_p SITES_ENABLED_PATH
    end

    # Copy certs for ssl. Just copy files once to keep the certificate static.
    ['mykey.pem', 'mycert.pem'].each { |cert_file|
      unless File.exist?("#{NGINX_PATH}/#{cert_file}") &&
          !File.zero?("#{NGINX_PATH}/#{cert_file}")
        FileUtils.cp("#{Djinn::APPSCALE_CONFIG_DIR}/certs/#{cert_file}",
                     "#{NGINX_PATH}/#{cert_file}")
      end
    }

    # Write the main configuration file which sets default configuration parameters
    File.open(MAIN_CONFIG_FILE, "w+") { |dest_file| dest_file.write(config) }

    # The pid file location was changed in the default nginx config for
    # Trusty. Because of this, the first reload after writing the new config
    # will fail on Precise.
    HelperFunctions.shell('service nginx restart')
  end
end
