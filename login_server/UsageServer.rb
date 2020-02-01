#!/usr/bin/env ruby -wKU

require 'socket'
require 'thread'
require 'rubygems'
require 'json'
require 'active_record'
require "#{File.dirname(__FILE__)}/Usage.rb"

ActiveRecord::Base.establish_connection(
  :adapter => 'mysql',
  :host => 'localhost',
  :database => 'userlog',
  :username => 'username',
  :password => 'password'
)

SALT = "salt"

# init some classes for AR
class Login < ActiveRecord::Base
end

class App < ActiveRecord::Base
end

class UsageServer
  def initialize(port)
    @port = port
	  puts "Hello, User Login TCP Server here, accepting connections"
  end

  # Bind to our port and listen for the magic
  def start
    server = TCPServer.new(4522)
    while true
      Thread.start(server.accept) do |s|
        print(s.peeraddr, " is accepted\n")
        while s.gets
          print(s.peeraddr, " sent data\n")
          handle($_, s)
        end
        print(s, " is gone\n")
        s.close
      end
    end
  end
  
  # Method to handle the packet. Fork a new thread each time since active record can be a bit slow sometimes
  def handle(p, socket)
    Thread.new {
      puts "\t\tparsing JSON"
      puts p
      h = JSON.parse(p)
      if h.is_a? Hash
        puts "\t\t\tis a valid hash"
        if h["action"] == "new session"
          puts "\t\t\t\t inserting new session"
          id = insertSession(h)
          puts "id returned: #{id}"
          socket.puts id
        else
          puts "\t\t\tupdating session"
          updateSession(h["session_id"], h)
        end
      else
        puts "\t\t\tis not a valid hash"
      end
      puts "#{h["username"]} (#{h["shaname"]}) logged into #{h["computername"]} (#{h["macaddress"]}, #{h["ipaddress"]}) at #{h["logindate"]}"
      h["apps"].each_pair { |app,dur| puts "\tUsed #{app} for #{dur} seconds" }
    }
  end
  
  
  def insertSession(h)
    u = Login.new
    puts "created new login instance: #{u}"
    u.computername = h["computername"]
    u.macaddress = h["macaddress"]
    u.ipaddress = h["ipaddress"]
    u.logindate = h["logindate"]
    u.shaname = Digest::SHA1.hexdigest(h["username"] + SALT)
    
    # close out all previous open sessions
    closePreviousSessions(h["computername"])
    puts "closed previous sesions for #{h["computername"]}"
    puts u.inspect
    # strip out the apps since they go into another table, leaving just the login/logout data
    u.save
    puts u.inspect
    return u.id
      
  end
  
  
  def closePreviousSessions(name)
    sessions = Login.all(:conditions => 'logoutdate IS NULL and computername = "#{name}"')
    sessions.each do |s|
      s.update_attribute(logoutdate, Time.now())
      s.update_attribute(logoutaccurate, "N")
    end
  end
  
  
  # Update the user and login information first, then the app usage data. Uses some active record models
  #  to make things a bunch more flexible if I decide to change things in the future
  def updateSession(id, h)
    puts "looking for #{id}"
    begin
      u = Login.find(id)
    rescue ActiveRecord::RecordNotFound
      puts "didn't find #{id}, creating new"
      u = Login.new
      u.computername = h["computername"]
      u.macaddress = h["macaddress"]
      u.ipaddress = h["ipaddress"]
      u.logindate = h["logindate"]
      u.shaname = h["shaname"]
    end
    
    puts u.inspect
    
    u.logoutdate = h["logoutdate"]
    u.logoutaccurate = h["logoutaccurate"]
    
    
    if u.save
      # now save the app usage data
      h["apps"].each_pair do |app,dur|
        a = App.new
        a.name, a.duration = app, dur
        a.session_id = u.id
        a.save
      end
    end
  end
end