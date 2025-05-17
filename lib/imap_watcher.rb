# frozen_string_literal: true

require 'English'
require 'logger'
require 'set'
require 'time'

require_relative 'options'
require_relative 'db'
require_relative 'fetched_mail'
require_relative 'mail_client'

# The ImapWatcher namespace.
module ImapWatcher
  # The entrypoint.
  #
  # @return [void]
  def self.main(argv = ARGV)
    options = parse_options(argv)

    server = options[:server]
    port = options[:port]
    user = options[:user]
    password = options[:password]
    mailbox = options[:mailbox]
    database_file = options[:database]
    command = options[:command]
    dead_letter_command = if options.include?(:'dead-letter-command')
                            options[:'dead-letter-command']
                          else
                            command
                          end
    initial_fetch_count = options[:'initial-fetch-count']
    fetch_source = options[:'fetch-source']
    use_tls = options[:tls]
    use_starttls = options[:starttls]
    verify = options[:verify]
    certificate = options[:certificate]
    dead_letter_queue_interval = options[:'dead-letter-queue-interval']
    debug = options[:debug]

    LOGGER.info 'Connecting to IMAP server...'

    imap = initialize_imap(
      server: server,
      port: port,
      user: user,
      password: password,
      use_tls: use_tls,
      use_starttls: use_starttls,
      verify: verify,
      certificate: certificate,
      mailbox: mailbox,
      debug: debug,
    )

    handler = ExternalCommandMailHandler.new(command, dead_letter_command)

    with_database(database_file) do |database|
      tables = DatabaseTables.new(database)
      tables.create_tables

      LOGGER.info 'Checking dead letters...'
      tables.transaction(:exclusive) do
        process_dead_letters(tables, handler)
      end

      check_initial_status(
        imap,
        tables,
        handler,
        initial_fetch_count,
        fetch_source
      )

      start_loop(
        imap,
        tables,
        handler,
        dead_letter_queue_interval,
        fetch_source
      )
    end

    imap.logout
  rescue EOFError
    sleep 60
    retry
  rescue Interrupt
    LOGGER.info 'Interrupted.'
  end

  # Check the UIDVALIDITY and fixes the last knwon UID if needed.
  #
  # If the UIDVALIDITY has changed, processes new mails after fixing the last
  # knwon UID.
  #
  # If UIDVALIDITY is not available in the database, fetches initial mails.
  #
  # @param imap [Net::IMAP] the IMAP object
  # @param tables [DatabaseTables] the database tables
  # @param handler [MailHandler] the mail handler
  # @param initial_fetch_count [Fixnum]
  #   the number of mails to be fetched on the initial startup
  # @param fetch_source [Boolean]
  #   fetches entire RFC 5322 message if and only if true
  # @return [void]
  def self.check_initial_status(
        imap,
        tables,
        handler,
        initial_fetch_count,
        fetch_source
      )
    count = last_sequence_number(imap)
    uid_validity = imap.responses['UIDVALIDITY'].last

    LOGGER.info 'Checking UIDVALIDITY...'
    tables.transaction(:exclusive) do
      saved_uid_validity = tables.last_uid_table.fetch_uid_validity

      if saved_uid_validity.nil?
        fetch_and_store_initial_messages(
          imap, tables, uid_validity, count, initial_fetch_count
        )
      elsif saved_uid_validity != uid_validity
        fix_last_uid(imap, tables, uid_validity, count)
        process_new_messages(
          imap,
          tables,
          handler,
          fetch_source
        )
      end
    end
  end

  # Starts the mail loop.
  #
  # Waits for new messages and process it.  Also processes dead letters
  # periodically.
  #
  # @param imap [Net::IMAP] the IMAP object
  # @param tables [DatabaseTables] the database tables
  # @param handler [MailHandler] the mail handler
  # @param dead_letter_queue_interval [Fixnum]
  #   the interval between re-delivering dead letters, in seconds
  # @param fetch_source [Boolean]
  #   fetches entire RFC 5322 message if and only if true
  # @return [void]
  def self.start_loop(
        imap,
        tables,
        handler,
        dead_letter_queue_interval,
        fetch_source
      )
    mutex = Thread::Mutex.new

    dead_letter_thread = Thread.new do
      loop do
        sleep dead_letter_queue_interval
        mutex.synchronize do
          tables.transaction(:exclusive) do
            process_dead_letters(tables, handler)
          end
        end
      end
    end

    loop do
      mutex.synchronize do
        tables.transaction(:exclusive) do
          process_new_messages(
            imap,
            tables,
            handler,
            fetch_source
          )
        end
      end

      imap.responses.clear

      timeout = 15 * 60

      imap.idle(timeout) do |response|
        imap.idle_done if response.name == 'EXISTS'
      end

      # Checkes exceptions.
      dead_letter_thread.join(0)
    end
  end

  # The interface for mail handler.
  class MailHandler
    # @param mail [FetchedMail] the mail to process
    def process_mail(mail) end

    # @param mail [DeadLetter, FetchedMail] the dead letter to process
    def process_dead_letter(mail) end
  end

  # A mail handler that deligates to the external command.
  #
  # If the command is nil, the mail is written to $stdout.
  #
  # The command string will be evalueated by the shell.
  #
  # The commands will be fed JSON on its standard input.
  class ExternalCommandMailHandler < MailHandler
    # @param command [String] the command for mail
    # @param dead_letter_command [String, nil]
    #   the command for dead letter command.  Default to command
    def initialize(command, dead_letter_command = command)
      super()
      @command = command
      @dead_letter_command = dead_letter_command
    end

    # @param mail [FetchedMail] the mail to process
    def process_mail(mail)
      open_executable(@command) do |io|
        io.puts(mail.to_h.to_json)
      end

      status = $CHILD_STATUS

      status.success?
    end

    # @param mail [DeadLetter, FetchedMail] the dead letter to process
    def process_dead_letter(mail)
      open_executable(@dead_letter_command) do |io|
        hash = mail.to_h
        hash.delete(:id)
        io.puts(hash.to_json)
      end

      status = $CHILD_STATUS

      status.success?
    end

    private

    # Creates a process with a pipe to the standard input.
    #
    # The block is invoked with IO object piped to the standard input of the
    # process.
    #
    # If the executable is nil, the block is invoked with $stdout.
    #
    # @param executable [String, nil] the executable
    # @yieldparam writer [IO] the pipe to the standard input of the process
    # @return [void]
    def open_executable(executable, &block)
      if executable.nil?
        yield $stdout
      else
        IO.popen(executable, 'w', &block)
      end
    end
  end

  private

  # The logger for imap-watcher.
  LOGGER = Logger.new($stderr)
  private_constant :LOGGER

  # Fetches existing message IDs and store in the database.
  #
  # Those mails are considered as old and not passed to the handler.
  #
  # Also inserts the UIDVALIDITY and UID to {LastUidTable}.
  #
  # @param imap [IMAP] the IMAP object
  # @param tables [DatabaseTables] the database tables
  # @param uid_validity [Fixnum] the current UIDVALIDITY
  # @param max_sequence_number [Fixnum]
  #   the maximum known sequence number of mails
  # @param fetch_count [Fixnum] the number of mails to fetch
  # @return [void]
  def fetch_and_store_initial_messages(
        imap,
        tables,
        uid_validity,
        max_sequence_number,
        fetch_count
      )
    LOGGER.info('Fetching initial messages...')
    mails = fetch_message_ids(imap, max_sequence_number, fetch_count)

    mails.each do |mail|
      tables.message_ids_table.insert(mail.message_id) if mail.message_id
    end

    last_uid = mails.map(&:uid).max

    tables.last_uid_table.insert(uid_validity, last_uid)
    LOGGER.info('Done fetching initial messages.')
  end

  # Fix the last known UID in LastUidTable using known message ID.
  #
  # If a mail with known message ID is found on the server, its UID is used.
  # Otherwise, set the last known UID as 0.
  #
  # @param imap [IMAP] the IMAP object
  # @param tables [DatabaseTables] the database tables
  # @param uid_validity [Fixnum] the current UIDVALIDITY
  # @param max_sequence_number [Fixnum]
  #   the maximum known sequence number of mails
  # @return [void]
  def fix_last_uid(imap, tables, uid_validity, max_sequence_number)
    LOGGER.info('UIDVALIDITY has changed.  Recovering...')

    last_uid = nil

    chunked_message_id_enumerator(imap, max_sequence_number).each do |messages|
      message_ids = messages.filter_map(&:message_id)
      matched_ids = tables.message_ids_table.query_ids(message_ids)

      next if matched_ids.empty?

      last_uid = messages.find do |message|
        matched_ids.include?(message.message_id)
      end.uid
      break
    end

    tables.last_uid_table.clear
    tables.last_uid_table.insert(uid_validity, last_uid || 0)

    LOGGER.info('Done recovering.')
  end

  # @param imap [IMAP] the IMAP object
  # @return [Fixnum] the maximum known sequence number of mails if known
  # @return [nil] otherwise
  def last_sequence_number(imap)
    if imap.responses['EXISTS'] && !imap.responses['EXISTS'].empty?
      imap.responses['EXISTS'].last
    else
      nil
    end
  end

  # Fetches new mails from the server and invoke the handler.
  #
  # This must be called in a database transaction.
  #
  # If the handler returns false or throws exceptions, dead letter handler is
  # invoked, and if the handler returns non-zero exit status again, the mail is
  # queued to the dead letter queue.
  #
  # Updates {LastUidTable}, {MailQueueTable}, and {DeadLetterQueueTable}.
  #
  # @param imap [IMAP] the IMAP object
  # @param tables [DatabaseTables] the database tables
  # @param handler [MailHandler] the mail handler
  # @param fetch_source [Boolean] fetch the entire message if and only if true
  # @return [void]
  def process_new_messages(
        imap,
        tables,
        handler,
        fetch_source
      )
    return unless last_sequence_number(imap)

    LOGGER.info('Fetching new messages...')
    last_uid = tables.last_uid_table.fetch_uid

    while last_sequence_number(imap)
      max_sequence_number = last_sequence_number(imap)
      imap.responses['EXISTS'].clear
      last_uid = do_process_new_messages(
        imap,
        tables,
        handler,
        fetch_source,
        max_sequence_number,
        last_uid
      )
    end

    tables.last_uid_table.update_uid(last_uid)

    LOGGER.info('Done fetching new messages.')
  end

  # Helper method for {#process_new_messages}.
  def do_process_new_messages(
        imap,
        tables,
        handler,
        fetch_source,
        max_sequence_number,
        last_uid
      )
    mail_enumerator(
      imap,
      max_sequence_number,
      fetch_source: fetch_source
    ).lazy.take_while { |mail| mail.uid > last_uid }.each do |mail|
      tables.mail_queue_table.insert(mail)
    end

    new_uid = last_uid

    tables.mail_queue_table.scan do |mail|
      begin
        handler.process_mail(mail) or raise 'could not handle the mail'
      rescue StandardError => e
        begin
          LOGGER.info "error: #{e}"
          handler.process_dead_letter(mail) or
            raise 'could not handle the dead letter'
        rescue StandardError => e
          id = mail.message_id
          LOGGER.info "error: #{e}"
          LOGGER.info "saving message #{id} to the dead letter queue"
          tables.dead_letter_queue_table.insert(mail)
        end
      end
      message_id = mail.message_id
      tables.message_ids_table.insert(message_id) unless message_id.nil?
      new_uid = mail.uid
    end

    tables.mail_queue_table.clear

    new_uid
  end

  # Scans mails in the dead letter queue and invoke the handler.
  #
  # This must be called in a database transaction.
  #
  # Updates {DeadLetterQueueTable}.
  #
  # @param tables [DatabaseTables] the database tables
  # @param handler [MailHandler] the mail handler
  # @return [void]
  def process_dead_letters(tables, handler)
    first_mail = true
    tables.dead_letter_queue_table.scan do |mail|
      if first_mail
        LOGGER.info 'Found dead letters.'
        first_mail = false
      end
      begin
        succeeded = handler.process_dead_letter(mail)

        tables.dead_letter_queue_table.delete(mail.id) if succeeded
      rescue StandardError => e
        LOGGER.info "error: #{e}"
      end
    end
  end

  extend self
end
