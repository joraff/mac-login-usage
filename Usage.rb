#!/usr/bin/env ruby -wKU

=begin

A little about this script...
To start the magic, call Usage::start from another script. This will set the login time to the current time
  and start the loop of seeing what app is currently being used. To do this, it runs a short applescript that
  gets the name of the frontmost application. It keeps these names in a hash with the amount of seconds its been in the front.
  Obviously this won't get anything thats in the background, but its a lot simpler than watching the CPU cycles.
  When someone logs out, the time is recorded as the logout time, and the packet is sent off to our server.
  To keep from loosing data in case someone just pulls the plug (which happens pretty often here), we write out our
  data to disk every time its updated, along with a lastUpdated value. That way we can retain any information from
  someone using the computer before it was inappropriately shutdown.
  
  This requires a companion UDP server that will "reHashify" the data and record it somehow
=end

gem_list = `gem list`
system 'gem install json_pure' unless gem_list.include? "json"

require 'socket'
require 'rubygems'
require 'json'
require 'digest/sha1'
require 'thread'

@HOST = "usage.server"
@PORT = 4522

class Usage
  
  def initialize
    # Some notes about this interval... If set too high, you might loose some usage information from rapid switches
    #  but, if set too low, you might experience some performance hit for really long sessions (the session data is written to disk at this interval, too)
    # I think any lower than 5 is too much disk activity, but higher than 30 will cause inaccurate data.
    @interval = 5
    @f = "/private/tmp/sessionData"
    @sessions = Array.new
  end
  
  # Checks for a previous, unprocessed session file.
  #  if found, it processes and sends the information to the server and starts over
  # Note: normal logouts, restarts, shutdowns, or kills are handled by the INT trap and logout method.
  #  If a power loss or hard shutdown occurs, that's what this method is for. The logout time becomes the last recorded time in the hash
  def parse_previous
    log "parsing previous"
    if File.exists?(@f) && !File.size(@f).zero?
      f = File.open(@f)
      begin
        f.each_line do |line|
          h = JSON.parse(line)
          h["logoutdate"] = h.logoutdate
          @sessions.push(h)
        end
        log "added #{@sessions.length} sessions(s) to sessions hash"
      rescue JSON::ParserError
        puts "JSON data incorrect"
      end
    else
      log "no previous data to parse"
    end
    unless @sessions.empty?
      handle_session_data
    end
  end
  
  def handle_session_data
    # Check to make sure we have network connectivity
    net = false

    3.times { |i|  
      en0 = `ifconfig en0 | grep "inet " | awk '{print $2}'`.rstrip
      en1 = `ifconfig en1 | grep "inet " | awk '{print $2}'`.rstrip
      if en0 =~ /129\.62/ || en1 =~ /129\.62/
        net = true
        break
    	else
    	  log "Waiting for the network to come up (i=#{i})"
    	  sleep 5 # seconds
    	end
    }

    unless net == true
      log "No network after 15 seconds, giving up"
    else
      log "We have network, sending #{@sessions.length} packets"
      @sessions.each do |h|
        if(h.is_a? Hash)
          if self.send_packet(h)
            # Do some cleanup
            @sessions.delete(h)
            log "Successfully sent session #{h["session_id"]}/#{h["username"]}, deleting from file"
            self.update_file
          else
            log "Error sending close packet for #{h["session_id"]}"
          end
        end
      end
    end
  end
  
  # Method that sends the session information to our packet server
  #  gathers information about the machine we're on then opens a socket to our server
  #  and sends our json session information Hash
  def send_packet(h)
    log "Sending packet to close session #{h.to_json}"
    h["logoutaccurate"] = 'Y'
    begin
      s = TCPSocket.new(@HOST, @PORT)
      s.puts h.to_json
      s.close
      true
    rescue Errno::ETIMEDOUT
      false
    end
  end
  
  def open_db_session
    h = @data.dup
    log "Sending packet to open session for #{h["username"]}"
    h["action"] = "new session"
    s = TCPSocket.new(@HOST, @PORT)
    puts h.to_json
    s.puts h.to_json
    id = s.recv(4096)
    s.close
    log "New ID for #{h["username"]} returned = #{id}"
    return id
  end
  
  # Starts the process of capturing the application usage data
  #  basically, it loops every @interval seconds and sees what app is in the front
  #  then increments that app's usage time in our session data hash (via the update method)
  # Note: traps an interrupt so that we can record our logout time.
  def start
    @data = { "computername" => `/usr/sbin/scutil --get ComputerName`.rstrip,
              "macaddress" => `/sbin/ifconfig en0 | grep 'ether' | awk '{print $2}'`.rstrip,
              "logindate" => Time.now,
              "apps" => Hash.new,
              "logoutdate" => nil,
              "lastUpdated" => Time.now }
    
    @data["ipaddress"] = `/sbin/ifconfig en0 | grep 'inet ' | awk '{print $2}'`.rstrip
    if @data["ipaddress"].empty? # Try the airport interface
      @data["ipaddress"] = `/sbin/ifconfig en1 | grep 'inet ' | awk '{print $2}'`.rstrip
    end
    
    #check for previous session file
    if File.exist?(@f) 
      self.parse_previous
    end
    #start recording new data
    
    ['TERM', 'INT'].each do |signal|
      trap(signal) {
        self.logout
        exit
      }
    end
    
=begin
  A little note about what these next two lines mean in the large picture...
  we decided to only keep the username for 7 days, in case something comes up that we'd need to track.
  So we also send the SHA version of the username to keep indefinitey so that we can still search on the uniqueness of users
=end

    @data["username"] = u = `id -un`.rstrip.upcase # Apple warned us not to use whoami anymore
    
    @data["session_id"] = self.open_db_session
    
    log "Recording usage data for #{@data["username"]}"
    
    while true
      sleep @interval
      app = `osascript -e "name of (info for (path to frontmost application))"`.gsub(".app", "").to_s.rstrip
      if app.length
        self.update(app)
      end
    end
  end
  
  # Takes the name of an app and increments its usage time by @interval seconds
  #  then writes out our session data to disk (in case of a power loss)
  def update(s) #(name of app: string)
    unless @data["apps"][s].nil?
      @data["apps"][s] += @interval
    else
      @data["apps"][s] = @interval
    end
    @data["lastUpdated"] = Time.now
    self.update_file
  end
  
  # Writes out our session data to disk (in case of a power loss)
  def update_file #(data hash)
    str = 
    #log "Updating file.. writing #{@sessions.length} previous sessions" + (@data && " plus 1 current session" || "")
    f = File.new(@f, "w+")
    # Handle previously unreported sessions first
    @sessions.each { |d| 
      f.puts d.to_json 
    }
    f.puts @data.to_json if @data
    if File.owned? f
      f.chmod(0777)
    end
    f.close
    
  end
  
  # Method called when the script exits, records our logout time maaking the data complete
  #  then sends it off to our server, then preps for the next user
  def logout
    log "Caught logout event for #{@data["username"]}. Updating hash"
    @data["logoutdate"] = Time.now
    @sessions.push(@data)
    @data = nil
    handle_session_data
  end
end

class Hash
  # Verifies that we have a good, understandable set of data
  def valid?
    puts self.inspect
    v = true
    unless self["apps"].is_a? Hash then puts "invalid :apps"; v = false end
    unless self["logindate"].is_a? Time then puts "invalid :logindate"; v = false end
    if self["logoutdate"].nil?
      unless self["lastUpdated"].is_a? Time then puts "invalid :lastUpdated"; v = false end
    end
    v
  end
  
  def logoutdate
    d = nil
    # Return the official logout
    if self["logoutdate"].nil? || !self["logoutdate"].is_a?(Time)
      # If we don't have that, send the last updated time
      if self["lastUpdated"].nil? || !self["lastUpdated"].is_a?(Time)
        # Finally, if we don't have that
        d = Time.now
      else
        d = self["lastUpdated"]
      end
    else
      d = self["logoutdate"]
    end
    d
  end
  
end

def log(s)
  `logger "#{s}"`
  puts s
end
