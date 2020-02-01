#!/usr/bin/env ruby -wKU

require "#{File.dirname(__FILE__)}/UsageServer.rb"

server = UsageServer.new('4522')
server.start