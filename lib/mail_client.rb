# frozen_string_literal: true

require 'mail'
require 'net/imap'
require 'openssl'

# The ImapWatcher namespace.
module ImapWatcher
  # Creates and returns a new Net::IMAP.
  #
  # @param server [String] the IMAP server address
  # @param port [Fixnum] the IMAP server port
  # @param user [String, nil] the IMAP server username
  # @param password [String, nil] the IMAP server password
  # @param use_tls [Boolean]
  #   encrypts connection using TLS if and only if true
  # @param use_starttls [Boolean]
  #   encrypts connection using STARTTLS if and only if true
  # @param verify [Boolean] verifies server certificate if and only if true
  # @param certificate [String, nil] the path to CA certificate file/directory
  # @param mailbox [String] the mailbox to watch
  # @param debug [Boolean]
  #   shows communications to the server if and only if true
  # @return [Net::IMAP]
  def initialize_imap(
        server:,
        port:,
        user:,
        password:,
        use_tls: false,
        use_starttls: false,
        verify: true,
        certificate: nil,
        mailbox: 'INBOX',
        debug: false
      )
    Net::IMAP.debug = debug

    ssl_params = {}

    if certificate
      if File.file?(certificate)
        ssl_params[:ca_file] = certificate
      else
        ssl_params[:ca_path] = certificate
      end
    end

    ssl_params[:verify_mode] =
      if verify
        OpenSSL::SSL::VERIFY_PEER
      else
        OpenSSL::SSL::VERIFY_NONE
      end

    imap = Net::IMAP.new(
      server,
      port: port,
      ssl: use_tls ? ssl_params : nil
    )

    imap.starttls(ssl_params) if use_starttls
    imap.authenticate('PLAIN', user, password) if user && password
    imap.examine(mailbox)

    imap
  end

  # Fetches and returns message IDs from the server.
  #
  # Fetches fetch_count mails from the given sequence number in descending
  # order.
  #
  # Returned {FetchedMail} only contains uid and message_id.
  #
  # @param imap [Net::IMAP] the IMAP object
  # @param from [Fixnum] the maximum sequence number
  # @param fetch_count [Fixnum] the count of mails to fetch
  # @return [Array<FetchedMail>]
  def fetch_message_ids(imap, from, fetch_count)
    headers_key = 'BODY[HEADER.FIELDS (MESSAGE-ID)]'

    do_fetch(imap, from, fetch_count, headers_key) do |uid, message|
      FetchedMail.new(uid: uid, message_id: message.message_id)
    end
  end

  # Return an Enumerator of chunks of messages.
  #
  # The enumerator fetches a few mails from the server lazily.
  # The number of mails to fetches starts from a small number, then grows to
  # max_fetch_count.
  #
  # Fetches from the given sequence number in descending order.
  #
  # @param imap [IMAP] the IMAP object
  # @param from [Fixnum] the maximum sequence number
  # @param max_fetch_count [Fixnum] the maximum size of chunks
  # @return [Enumerator<Array<FetchedMail>>]
  def chunked_message_id_enumerator(imap, from, max_fetch_count = 100)
    fetch_range_enumerator(
      from, max_fetch_count
    ).lazy.map do |sequence_number, fetch_count|
      fetch_message_ids(imap, sequence_number, fetch_count)
        .sort_by!(&:uid)
        .reverse!
    end.eager
  end

  # Fetches and returns mails from the server.
  #
  # Fetches fetch_count mails from the given sequence number in descending
  # order.
  #
  # @param imap [Net::IMAP] the IMAP object
  # @param from [Fixnum] the maximum sequence number
  # @param fetch_count [Fixnum] the count of mails to fetch
  # @param fetch_source [Boolean]
  #   fetches entire RFC 5322 message if and only if true
  # @return [Array<FetchedMail>]
  def fetch_mails(imap, from, fetch_count, fetch_source: false)
    headers_key = 'BODY[HEADER.FIELDS (DATE MESSAGE-ID FROM TO CC SUBJECT)]'

    do_fetch(
      imap,
      from,
      fetch_count,
      headers_key,
      fetch_source: fetch_source
    ) do |uid, message, source|
      FetchedMail.new(
        uid: uid,
        timestamp: message.date.to_time.to_i,
        message_id: message.message_id,
        from: message.from,
        to: message.to,
        cc: message.cc,
        subject: message.subject,
        source: source,
      )
    end
  end

  # Helper method for {#fetch_mails} and {#fetch_message_ids}.
  def do_fetch(imap, from, fetch_count, headers_key, fetch_source: false)
    return [] if from.zero? || fetch_count.zero?

    keys = ['UID', headers_key]

    keys.push('BODY[]') if fetch_source

    to = [1, from - fetch_count + 1].max

    (imap.fetch(to..from, keys) || []).map do |raw_message|
      uid = raw_message.attr['UID']
      message = Mail.read_from_string(raw_message.attr[headers_key])
      source = fetch_source ? raw_message.attr['BODY[]'] : nil

      yield uid, message, source
    end
  end

  private :do_fetch

  # Returns an Enumerator of ranges of sequence numbers to fetch.
  #
  # Starts from the given sequence number in descending order.
  # The number of mails to fetches starts from a small number, then grows to
  # max_fetch_count.
  #
  # @param max_sequence_number [Fixnum] the maximum sequence number
  # @param max_fetch_count [Fixnum] the maximum size of ranges
  # @return [Enumerator<(Fixnum, Fixnum)>]
  #   an enumerator of pair of sequence number and count
  def fetch_range_enumerator(max_sequence_number, max_fetch_count)
    # 2, 4, 8, ..., max_fetch_count, max_fetch_count, ...
    fetch_counts =
      Enumerator
        .produce(2) { |i| i * 2 }
        .take_while { |i| i < max_fetch_count }.to_enum +
      Enumerator
        .produce { max_fetch_count }

    # Enumerator of pairs of sequence number and fetch count.
    Enumerator.new do |yielder|
      fetch_counts.reduce(max_sequence_number) do |sequence_number, count|
        break if sequence_number < 1

        yielder.yield sequence_number, count
        sequence_number - count
      end
    end
  end

  # Returns an enumerator of mails.
  #
  # The enumerator fetches a few mails from the server lazily in descending
  # order.
  #
  # @param imap [Net::IMAP] the IMAP object
  # @param max_sequence_number [Fixnum] the maximum sequence number
  # @param fetch_source [Boolean]
  #   fetches entire RFC 5322 message if and only if true
  # @return [Enumerator<FetchedMail>]
  def mail_enumerator(imap, max_sequence_number, fetch_source: false)
    fetch_range_enumerator(
      max_sequence_number, 100
    ).lazy.flat_map do |sequence_number, fetch_count|
      fetch_mails(
        imap,
        sequence_number,
        fetch_count,
        fetch_source: fetch_source
      ).sort_by!(&:uid).reverse!
    end.eager
  end
end
