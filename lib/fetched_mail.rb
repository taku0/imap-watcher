# frozen_string_literal: true

# The ImapWatcher namespace.
module ImapWatcher
  # Mails fetched from the server.
  #
  # @!method initialize(...)
  #   Returns a new instance of FetchedMail.
  #
  #   Accepts attributes as keyword parameters.
  #
  #   @return [FetchedMail]
  #
  # @!attribute [r] uid
  #   @return [Fixnum] the UID
  # @!attribute [r] timestamp
  #   @return [Fixnum] the timestamp of the mail in a UNIX time
  # @!attribute [r] message_id
  #   @return [String] the Message-ID of the mail
  # @!attribute [r] from
  #   @return [Array<String>] the From mail addresses
  # @!attribute [r] to
  #   @return [Array<String>] the To mail addresses
  # @!attribute [r] cc
  #   @return [Array<String>] the Cc mail addresses
  # @!attribute [r] subject
  #   @return [String] the Subject
  # @!attribute [r] source
  #   @return [String, nil] the the RFC 5322 expression of the entire message
  FetchedMail = Struct.new(
    :uid, :timestamp, :message_id,
    :from, :to, :cc, :subject, :source,
    keyword_init: true
  )

  # Mails in the dead letter queue.
  #
  # @!method initialize(...)
  #   Returns a new instance of DeadLetter.
  #
  #   Accepts attributes as keyword parameters.
  #
  #   @return [DeadLetter]
  #
  # @!attribute [r] id
  #   @return [Fixnum, nil] the ID in the table.
  #     Maybe nil before inserting to the table
  # @!attribute [r] timestamp
  #   @return [Fixnum] the timestamp of the mail in a UNIX time
  # @!attribute [r] message_id
  #   @return [String] the Message-ID of the mail
  # @!attribute [r] from
  #   @return [Array<String>] the From mail addresses
  # @!attribute [r] to
  #   @return [Array<String>] the To mail addresses
  # @!attribute [r] cc
  #   @return [Array<String>] the Cc mail addresses
  # @!attribute [r] subject
  #   @return [String] the Subject
  # @!attribute [r] source
  #   @return [String, nil] the the RFC 5322 expression of the entire message
  DeadLetter = Struct.new(
    :id, :timestamp, :message_id,
    :from, :to, :cc, :subject, :source,
    keyword_init: true
  )
end
