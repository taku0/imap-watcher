# frozen_string_literal: true

require 'optparse'
require 'json'

# The ImapWatcher namespace.
module ImapWatcher
  # An OptionParser for imap-watcher.
  OPTION_PARSER = OptionParser.new do |parser|
    parser.banner = "Usage: #{$PROGRAM_NAME} [options]"

    parser.on('--config PATH',
              'Path to configuration file.',
              'Default: $XDG_CONFIG_HOME/imap-watcher/config.json.',
              'The configuration file should contain JSON object.',
              'Its keys are the command line option names.')

    parser.on('--server SERVER',
              'IMAP server name.')

    parser.on('--port PORT',
              'IMAP Port.',
              'Default: 143 for unencrypted server. 993 for encrypted server')

    parser.on('--user USER',
              'User name.')

    parser.on('--password PASSWORD',
              'Password.')

    parser.on('--command COMMAND',
              'Command to execute on mails.  Evalueated by the shell.')

    parser.on('--dead-letter-command COMMAND',
              'Command to execute on dead letters.  Evalueated by the shell.',
              'Default: command given by --command')

    parser.on('--mailbox MAILBOX',
              'Mailbox to watch.',
              'Default: INBOX.')

    parser.on('--fetch-source',
              'Fetch entire RFC 5322 message.')

    parser.on('--database PATH',
              'Path to database.',
              'Default: $XDG_DATA_HOME/imap-watcher/mails.sqlite3.')

    parser.on('--tls',
              'Encrypt connection using TLS.',
              'Sometimes called SSL.  Not to be confused with --starttls.')

    parser.on('--starttls',
              'Encrypt connection using STARTTLS.',
              'Not to be confused with --tls.')

    parser.on('--[no-]verify',
              'Verify server when --tls or --starttls is used.',
              'Default: verify the server.')

    parser.on('--certificate PATH',
              'Path to CA certificate file/directory.')

    parser.on('--initial-fetch-count COUNT',
              'Number of mails to be fetched on the initial startup.',
              'Default: 10.',
              'Those mails are not passed to the executable.')

    parser.on('--dead-letter-retry-interval COUNT',
              'Interval between re-delivering dead letters, in seconds.',
              'Default: 3600.')

    parser.on('--debug',
              'Show communications between the IMAP server.')

    parser.on('-h', '--help', 'Prints this help.') do
      puts parser
      puts
      puts 'The command is executed whenever new mail is available.'
      puts 'The mail is passed to its standard input as a JSON object with the'
      puts 'following keys:'
      puts
      puts '  uid: The IMAP UID of the mail.  Not available for dead letters.'
      puts '  timestamp: The UNIX time of the Date header.'
      puts '  message_id: The Message-ID header without angle brackets.'
      puts '  from: An array of the From header addresses without angle'
      puts '        brackets.'
      puts '  to: An array of the To header addresses without angle brackets.'
      puts '  cc: An array of the Cc header addresses without angle brackets.'
      puts '  subject: The decoded Subject header.'
      puts '  source: The entire RFC 5322 message.'
      puts '          Available only if --fetch-source is set.'
      puts
      puts '## Message Delivery Reliability'
      puts
      puts 'imap-watcher struggles to deliver massage at-least-once.  If'
      puts 'imap-watcher exits abnormally, it will deliver the mail on the next'
      puts 'time.  Nevertheless, it may lose mails if mails are deleted on the'
      puts 'server before delivered.'
      puts
      puts 'To be precise, If the command returns non-zero exit status, dead'
      puts 'letter command is invoked, and if the command returns non-zero exit'
      puts 'status again, the mail is queued to the dead letter queue.  Then'
      puts 'mails in the dead letter queue will be re-delivered at start up and'
      puts 'at intervals of --dead-letter-retry-interval seconds.'
      exit
    end
  end

  # Parses command line options and returns the parsed options.
  #
  # @param argv [Array<String>] the command line options
  # @return [Hash<Symbol, String>]
  def parse_options(argv)
    options = {}

    OPTION_PARSER.parse!(argv, into: options)

    config_home = ENV['XDG_CONFIG_HOME'] ||
                  File.join(Dir.home || '/', '.config')

    configuration_file = options[:config] ||
                         File.join(config_home, 'imap-watcher', 'config.json')

    config =
      begin
        JSON.parse(File.read(configuration_file), symbolize_names: true)
      rescue Errno::ENOENT
        if options[:config]
          warn "Cannot open configuration file #{configuration_file}."
          exit 1
        end
        {}
      rescue e
        warn e
        exit 1
      end

    config.update(options)

    if config[:server].nil?
      warn '--server is required.'
      exit 1
    end

    config[:mailbox] = 'INBOX' if config[:mailbox].nil?

    if config[:database].nil?
      data_home = ENV['XDG_DATA_HOME'] ||
                  File.join(Dir.home || '/', '.local', 'share')

      config[:database] = File.join(data_home, 'imap-watcher', 'mails.sqlite3')
    end

    config[:validate] = true if config[:validate].nil?

    config[:'initial-fetch-count'] ||= 10

    config[:'dead-letter-queue-interval'] ||= 3600

    config
  end
end
