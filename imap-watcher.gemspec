# frozen_string_literal: true

Gem::Specification.new do |s|
  s.name        = 'imap-watcher'
  s.version     = '1.0.0'
  s.summary     = 'Execute command on new messages on IMAP server'
  s.description = 'imap-watcher watches on an IMAP server using IDLE command and execute command on new messages.'
  s.authors     = ['taku0']
  s.files       = Dir['lib/**/*.rb'] + Dir['bin/*'] + ['README.md', 'LICENSE.md']
  s.bindir      = 'bin'
  s.executables = Dir['bin/*'].map { |p| File.basename(p) }
  s.license     = 'MIT'

  s.required_ruby_version = '>=3.0'

  s.add_dependency 'mail', '~>2.7'
  s.add_dependency 'net-imap', '~>0.3'
  s.add_dependency 'net-pop'
  s.add_dependency 'net-smtp'
  s.add_dependency 'sqlite3', '~>1.5'
end
