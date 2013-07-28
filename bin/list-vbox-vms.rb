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
    :filter => /.*/,
    # :filter => /centos6/,
    :do_name => true,
    :do_vagrantfile_dir => true,
    :do_status => true,
    :do_user => true,

    # sum of harddisks
    # OS
    # guest additions version
    # memory
    # cpus
    # port offset
    # last legit login
    # PID
    # cpu time
    # user 
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

  #pp vmi
  
  return nil unless looks_like_vagrant(vmi)

  details = {}
  opts.select { |opt, val| opt =~ /^do_/ && val }.each do |task, flag|
    self.send(task, vmi, details)
  end

#   extract Vfile dir from shared folder list
#   extract portmappings
#   
  
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


def looks_like_vagrant(vmi)
  vmi.any? {|k,v| k =~ /^SharedFolderNameMachineMapping/ && v == 'v-root' }
end


def output_results (opts, results)
  puts JSON.pretty_generate(results)
end




main()
