require 'stringio'

require 'dinghy/machine'
require 'dinghy/constants'

class HttpProxy
  CONTAINER_NAME = "dinghy_http_proxy"
  IMAGE_NAME = "codekitchen/dinghy-http-proxy:2.3.1"
  RESOLVER_DIR = Pathname("/etc/resolver")

  attr_reader :machine, :resolver_file, :dinghy_domain

  def initialize(machine, dinghy_domain)
    @machine = machine
    self.dinghy_domain = dinghy_domain || "docker"
  end

  def name
    "Proxy"
  end

  def dinghy_domain=(dinghy_domain)
    @dinghy_domain = dinghy_domain
    @resolver_file = RESOLVER_DIR.join(@dinghy_domain)
  end

  def up(expose_proxy: true)
    puts "Starting DNS#{' and HTTP proxy' if expose_proxy}"
    unless resolver_configured?
      configure_resolver!
    end
    System.capture_output do
      docker.system("rm", "-fv", CONTAINER_NAME)
    end
    docker.system("run", "-d",
      *run_args(expose_proxy),
      "--name", CONTAINER_NAME, IMAGE_NAME)
  end

  def status
    return "stopped" if !machine.running?

    output, _ = System.capture_output do
      docker.system("inspect", "-f", "{{ .State.Running }}", CONTAINER_NAME)
    end

    if output.strip == "true"
      "running"
    else
      "stopped"
    end
  end

  def configure_resolver!
    puts "setting up DNS resolution, this will require sudo"
    unless RESOLVER_DIR.directory?
      system!("creating #{RESOLVER_DIR}", "sudo", "mkdir", "-p", RESOLVER_DIR)
    end
    Tempfile.open('dinghy-dnsmasq') do |f|
      f.write(resolver_contents)
      f.close
      system!("creating #{@resolver_file}", "sudo", "cp", f.path, @resolver_file)
      system!("creating #{@resolver_file}", "sudo", "chmod", "644", @resolver_file)
    end
    system!("restarting mDNSResponder", "sudo", "killall", "mDNSResponder")
  end

  def resolver_configured?
    @resolver_file.exist? && File.read(@resolver_file) == resolver_contents
  end

  def resolver_contents; <<-EOS.gsub(/^    /, '')
    # Generated by dinghy
    nameserver #{machine.vm_ip}
    port 19322
    EOS
  end

  private

  def run_args(expose_proxy = true)
    args = [
      "-p", "19322:19322/udp",
      "-v", "/var/run/docker.sock:/tmp/docker.sock:ro",
      "-v", "#{Dinghy.home_dinghy_certs}:/etc/nginx/certs",
      "-e", "CONTAINER_NAME=#{CONTAINER_NAME}",
      "-e", "DOMAIN_TLD=#{dinghy_domain}",
      "-e", "DNS_IP=#{machine.vm_ip}",
    ]
    if expose_proxy
      args += [
        "-p", "80:80",
        "-p", "443:443",
      ]
    end
    args
  end

  def docker
    @docker ||= Docker.new(machine)
  end

  def system!(step, *args)
    system(*args.map(&:to_s)) || raise("Error with the #{name} daemon during #{step}")
  end
end
