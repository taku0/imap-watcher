# frozen_string_literal: true

require 'rubocop/rake_task'
require 'yard'

desc 'Run linters'
task lint: [:rubocop]

desc 'Generate documents'
task doc: [:yard]

RuboCop::RakeTask.new

YARD::Rake::YardocTask.new
