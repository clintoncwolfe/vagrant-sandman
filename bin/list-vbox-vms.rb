#!/usr/bin/env ruby

require 'json'
require 'date'
require 'etc'
require 'pp'

def main
  opts = parse_opts
  vbm = find_virtualbox(opts)    
  results = list_vms(opts, vbm).
    select { |vm_name| vm_name =~ opts[:filter] }.
    map {|vm_name| get_vm_details(opts, vbm, vm_name) }.
    reject{|d| d.nil? }
  output_results(opts, results)
end

def parse_opts
  return {
    :running_only => false,
    # :filter => /.*/,
    :filter => /centos6/,
    :do_name => true,
    :do_vagrantfile_dir => true,
    :do_status => true,
    :do_user => true,
    :do_cpus => true,
    :do_memory => true,
    :do_pid => true,  # depends on status, name and user
    :do_ps_stats => true, # depends on status and pid
    :do_portmap => true,
    :do_guest_additions => true,
    :do_os_type => true,
    :do_disk_usage => true,
    :do_last_login => true,  # depends on status, vagrantfile dir
    :do_sandman_file => true, 

    # presence of sandman file
    # info from Vagrantfile
    #   git up to date?
    #   uses includes?
    #   vagrant config version?
    #   

  }
end

def find_virtualbox(opts)
  return `which VBoxManage`.chomp
end

def list_vms(opts, vbm)
  cmd = opts[:running_only] ? 'runningvms' : 'vms'
  vms = `#{vbm} list #{cmd}`.split(/\n/).map { |l| (l.split(/\s+/))[0].gsub('"', '') }
end

def get_vm_details(opts, vbm, vm_name) 
  # Run showvminfo
  vmi = Hash.new
  `#{vbm} showvminfo --machinereadable #{vm_name}`.split(/\n/).each do |line|
    match = line.match(/(?<key>.+)="?(?<val>[^"]*)"?$/)    
    vmi[match[:key]] = match[:val] if match
  end

  # pp vmi
  
  return nil unless looks_like_vagrant(vmi)

  details = {}
  opts.select { |opt, val| opt =~ /^do_/ && val }.each do |task, flag|
    self.send(task, vmi, details)
  end  
  return details
end

def do_name(v,d)
  d[:name] = v['name']
end

def do_vagrantfile_dir(v,d)
  mapping_name = v.keys.find {|k| k =~ /^SharedFolderNameMachineMapping/ && v[k] == 'v-root' }
  mapping_name = mapping_name.sub('FolderNameMachine', 'FolderPathMachine')
  d[:vagrantfile_dir] = v[mapping_name]

  dir_parts = d[:vagrantfile_dir].split('/') # TODO UNPORTABLE
  d[:project_vm] = dir_parts[-1]
  d[:project] = dir_parts[-2]
end

def do_status(v,d)
  d[:status] = v['VMState']
  # "VMStateChangeTime"=>"2013-07-26T19:54:36.354000000",
  d[:status_change_epoch] = DateTime.parse(v['VMStateChangeTime']).strftime('%s') 
end

def do_user(v,d)
  d[:username] = Etc.getpwuid(Process.euid).name
end

def do_pid(v,d)
  d[:pid] = nil
  if d[:status] == 'running' then
    entry = (`ps -u #{d[:username]} -o pid= -o args=`.split(/\n/).grep(/VBoxHeadless/).grep(Regexp.new(d[:name])))[0]
    if entry then
      entry.strip!
      d[:pid] = (entry.split(/\s+/))[0]
    end
  end
end                                                                                      

def do_ps_stats(v,d)
  d[:used_memory_kb] = nil
  d[:used_cpu_sec] = nil
  if d[:status] == 'running' then
    entry = `ps -p #{d[:pid]} -o vsz= -o time=`
    m = entry.match(/(?<vsz>\d+)\s+(?<days>\d{0,2})-?(?<hours>\d{2}):(?<minutes>\d{2}):(?<seconds>\d{2})/)
    if m then
      d[:used_memory_kb] = m[:vsz]
      d[:used_cpu_sec] = m[:seconds].to_i + m[:minutes].to_i*60 + m[:hours].to_i*3600 + (m[:days] || 0).to_i*3600*24
    end
  end
end

def do_memory(v,d)
  d[:assigned_memory_mb] = v['memory']
end

def do_cpus(v,d)
  d[:assigned_cpus] = v['cpus']
end

def do_portmap(v,d)
  d[:portmap] = Hash.new
  v.keys.grep(/Forwarding\(\d+\)/).each do |rulename|
    parts = v[rulename].split(',')
    d[:portmap][parts[5]] = parts[3]  # guest => host, 22 => 52022
  end
end

def do_guest_additions(v,d)
  d[:guest_additions_version] = nil
  if v["GuestAdditionsVersion"] then
    d[:guest_additions_version] = (v["GuestAdditionsVersion"].split(/\s+/))[0]
  end
end

def do_os_type(v,d)
  d[:os_type] = v["GuestOSType"] 
end

def do_disk_usage(v,d)
  d[:disk_usage] = 0
  v.keys.grep(/(SATA|IDE) Controller-\d+-\d+/).each do |attachment|
    next if v[attachment] == 'none'
    next if v[attachment] =~ /VBoxGuestAdditions\.iso/
    next unless File.exists?(v[attachment])
    d[:disk_usage] += File.size(v[attachment])
  end
end

def do_last_login(v,d)
  d[:last_login] = Hash.new()
  if d[:status] == 'running' then    
    #mpatil   pts/19       client-10-8-3-78 Tue Jul  2 14:28 - 00:06  (09:37)    
    re = /(\S+)\s+(?:\S+\/\d+)\s+(?:\S+)\s+(\S{3})\s+(\S{3})\s+(\d+)\s+(\d+):(\d{2})\s+-.+/
    `cd #{d[:vagrantfile_dir]}; vagrant ssh -c last`.scan(re).each do |match|
      (username, wday, mname, day, hour, min) = *match
      current_year = DateTime.now.year      
      [current_year, current_year - 1].each do |year|
        login_epoch = DateTime.parse("#{wday} #{mname} #{day} #{hour}:#{min}:00 #{year}").strftime("%s").to_i
        if login_epoch < DateTime.now.strftime('%s').to_i
          # It's a plausibly legit date, store the max (most recent) login epoch
          d[:last_login][username] ||= login_epoch
          d[:last_login][username] = login_epoch > d[:last_login][username] ? login_epoch : d[:last_login][username]          
          break
        else
          # Must be a login from last year
          next
        end
      end      
    end
  end
end

def do_sandman_file(v,d) 
  d[:sandman_file] = {}
  path = File.join(d[:vagrantfile_dir], '.sandman')
  if File.exists?(path) then
    begin
      d[:sandman_file] = JSON.parse(File.read(path))
    rescue Exception => ex
      # Just ignore?
    end
  end
end

def looks_like_vagrant(vmi)
  vmi.any? {|k,v| k =~ /^SharedFolderNameMachineMapping/ && v == 'v-root' }
end




def output_results (opts, results)
  puts JSON.pretty_generate(results)
end




main()
