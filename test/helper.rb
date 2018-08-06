require "rubygems"
require "bundler/setup"
begin
  Bundler.setup(:default, :development)
rescue Bundler::BundlerError => e
  $stderr.puts e.message
  $stderr.puts "Run `bundle install` to install missing gems"
  exit e.status_code
end

require 'pg'
require "active_record"
require "minitest/autorun"

# from https://github.com/rails/rails/issues/31673 - workaround for 4.2.x
module Kernel
  def gem_with_pg_fix(dep, *reqs)
    if dep == "pg" && reqs == ["~> 0.15"]
      reqs = ["~> 1.0"]
    end
    gem_without_pg_fix(dep, *reqs)
  end

  alias_method_chain :gem, :pg_fix
end
# pg 1.0 gem has removed these constants, but 4.2 ActiveRecord still expects them
PGconn   = PG::Connection
PGresult = PG::Result
PGError  = PG::Error

require "#{File.dirname(__FILE__)}/../init"

require "shared"
