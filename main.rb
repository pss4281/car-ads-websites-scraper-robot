require 'rubygems'
require 'bundler/setup'
require 'active_record'
require 'mechanize'
require 'progressbar'
require 'parallel'
require 'cgi'
require 'csv'
require 'logger'
require 'open-uri'
require 'digest'

log_file = File.open('log', 'w')
LOGGER = Logger.new(log_file)
LOGGER.level = Logger::DEBUG

require './ar_models.rb'
include ArModels

require './app.rb'

Parser.work