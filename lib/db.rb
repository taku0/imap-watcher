# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'sqlite3'

# The ImapWatcher namespace.
module ImapWatcher
  # Opens SQLite database file.
  #
  # If a block is given, it is invoked with the database and the database will
  # be closed upon return.  Otherwise, the database is retuned
  #
  # @param [String] file the SQLite database file
  # @yieldparam db [SQLite3::Database] the SQLite database
  # @yieldreturn [BasicObject] any value
  # @return [SQLite3::Database] if a block is not given, the SQLite database
  # @return [BasicObject] if a block is given, its return value
  def self.with_database(file)
    FileUtils.makedirs(File.dirname(file))

    db = SQLite3::Database.new(file)

    if block_given?
      begin
        db.busy_timeout(60 * 1000)
        yield db
      ensure
        db.close
      end
    else
      db
    end
  end

  # Database tables for imap-watcher.
  class DatabaseTables
    # @return [LastUidTable]
    attr_reader :last_uid_table

    # @return [MessageIdsTable]
    attr_reader :message_ids_table

    # @return [MailQueueTable]
    attr_reader :mail_queue_table

    # @return [DeadLetterQueueTable]
    attr_reader :dead_letter_queue_table

    # @param database [SQLite3::Database] a SQLite Database object
    def initialize(database)
      @database = database
      @last_uid_table = LastUidTable.new(@database)
      @message_ids_table = MessageIdsTable.new(@database)
      @mail_queue_table = MailQueueTable.new(@database)
      @dead_letter_queue_table = DeadLetterQueueTable.new(@database)
      @tables = [
        @last_uid_table,
        @message_ids_table,
        @mail_queue_table,
        @dead_letter_queue_table,
      ]
    end

    # Creates tables if not exists.
    #
    # @return [void]
    def create_tables
      @tables.each(&:create_table)
    end

    # Starts a transaction.
    #
    # If a block is given, invokes the block.  If the block returns without an
    # exception, the transaction is committed.  If the block raises an exception,
    # the transaction is rollbacked.
    #
    # @param level [:exclusive, :deferred, :immediate]
    #   the transaction isolation level
    # @yieldparam db [SQLite3::Database] the database object
    # @return [void]
    def transaction(level = :exclusive, &body)
      @database.transaction(level, &body)
    end
  end

  # Table that holds last knwon UID with UIDVALIDITY.
  #
  # This table holds only one row.
  class LastUidTable
    # @param database [Database] the SQLite Database object
    def initialize(database)
      @database = database
    end

    # Creates the table if not exists.
    #
    # @return [void]
    def create_table
      @database.execute_batch(
        [
          'CREATE TABLE IF NOT EXISTS last_uid (',
          '  uid_validity INTEGER NOT NULL,',
          '  uid INTEGER NOT NULL',
          ');',
        ].join("\n")
      )
    end

    # Deletes the values.
    #
    # @return [void]
    def clear
      @database.execute('DELETE FROM last_uid')
    end

    # Inserts the last known UIDVALIDITY and UID.
    #
    # @param uid_validity [Fixnum] the new UIDVALIDITY value
    # @param uid [Fixnum] the new UID value
    # @return [void]
    def insert(uid_validity, uid)
      @database.execute(
        'INSERT INTO last_uid (uid_validity, uid) VALUES (?, ?)',
        [uid_validity, uid]
      )
    end

    # Updates the last known UID.
    #
    # @param uid [Fixnum] the new UID value
    # @return [void]
    def update_uid(uid)
      @database.execute('UPDATE last_uid SET uid = ?', [uid])
    end

    # @return [Fixnum] the last known UID
    def fetch_uid
      @database.get_first_value('SELECT uid FROM last_uid')
    end

    # @return [Fixnum] the last known UIDVALIDITY
    def fetch_uid_validity
      @database.get_first_value('SELECT uid_validity FROM last_uid')
    end
  end

  # Table that holds a set of knwon Message-ID.
  class MessageIdsTable
    # @param database [SQLite3::Database] a SQLite Database object
    def initialize(database)
      @database = database
    end

    # Creates tables if not exists.
    #
    # @return [void]
    def create_table
      @database.execute_batch(
        [
          'CREATE TABLE IF NOT EXISTS message_ids (',
          '  id INTEGER PRIMARY KEY,',
          '  timestamp INTEGER NOT NULL DEFAULT (unixepoch()),',
          '  message_id TEXT NOT NULL UNIQUE',
          ');',
          '',
          'CREATE INDEX IF NOT EXISTS',
          '  message_ids_timestamp_key',
          'ON message_ids (',
          '  timestamp',
          ');',
        ].join("\n")
      )
    end

    # Inserts a message ID.
    #
    # @param id [String] and message ID
    # @return [void]
    def insert(id)
      @database.execute(
        'INSERT OR REPLACE INTO message_ids (message_id) VALUES (?)',
        [id]
      )
    end

    # Query all known message IDs in descending order.
    #
    # If a block is given, invokes it with a ResultSet, close the result set,
    # then return the result value of the block.
    #
    # Otherwise, returns the ResultSet.
    #
    # @yieldparam result [SQLite3::ResultSet] the query result
    # @yieldreturn [BasicObject] any value
    # @return [ResultSet] if the block is not given, the query result
    # @return [BasicObject] if the block is given, the result of the block
    def query_all(&block)
      @database.query(
        'SELECT message_id FROM message_ids ORDER BY id DESC',
        &block
      )
    end

    # Deletes message IDs older then the given timestamp.
    #
    # @param timestamp [Fixnum] a UNIX time
    # @return [void]
    def delete_older_than(timestamp)
      @database.execute(
        'DELETE FROM message_ids WHERE timestamp < ?', [timestamp]
      )
    end

    # @param message_ids [Array<String>]
    # @return [Array<String>]
    #   the intersection of given message IDs and message IDs in the table.
    def query_ids(message_ids)
      if message_ids.empty?
        []
      else
        placeholders = message_ids.map { '?' }.join(', ')
        @database.execute(
          [
            'SELECT',
            '  message_id',
            'FROM',
            '  message_ids',
            'WHERE',
            "  message_id IN (#{placeholders})",
          ].join("\n"),
          message_ids
        ).map do |row|
          row[0]
        end
      end
    end
  end

  # Table that act as a queue of new messages.
  class MailQueueTable
    # @param database [SQLite3::Database] a SQLite Database object
    def initialize(database)
      @database = database
    end

    # Creates the table if not exists.
    #
    # @return [void]
    def create_table
      @database.execute_batch(
        [
          'CREATE TABLE IF NOT EXISTS mail_queue (',
          '  uid INTEGER NOT NULL PRIMARY KEY,',
          '  timestamp INTEGER NOT NULL,',
          '  message_id TEXT,',
          '  "from" TEXT NOT NULL,',
          '  "to" TEXT NOT NULL,',
          '  cc TEXT NOT NULL,',
          '  subject TEXT,',
          '  source TEXT',
          ');',
        ].join("\n")
      )
    end

    # Inserts a mail into the queue.
    #
    # @param mail [FetchedMail]
    # @return [void]
    def insert(mail)
      @database.execute(
        [
          'INSERT OR IGNORE INTO mail_queue',
          '  (uid, timestamp, message_id, "from", "to", cc, subject, source)',
          'VALUES',
          '  (?, ?, ?, ?, ?, ?, ?, ?)',
        ].join("\n"),
        [
          mail.uid,
          mail.timestamp,
          mail.message_id,
          mail.from.to_json,
          mail.to.to_json,
          mail.cc.to_json,
          mail.subject,
          mail.source,
        ]
      )
    end

    # Clears the queue.
    #
    # @return [void]
    def clear
      @database.execute('DELETE FROM mail_queue')
    end

    # Scans queue order by UID in ascending order.
    #
    # @yieldparam mail [FetchedMail]
    # @return [void]
    def scan
      @database.execute(
        [
          'SELECT',
          '  uid,',
          '  timestamp,',
          '  message_id,',
          '  "from",',
          '  "to",',
          '  cc,',
          '  subject,',
          '  source',
          'FROM',
          '  mail_queue',
          'ORDER BY',
          '  uid',
        ].join("\n")
      ) do |row|
        yield FetchedMail.new(
                uid: row[0],
                timestamp: row[1],
                message_id: row[2],
                from: JSON.parse(row[3]) || [],
                to: JSON.parse(row[4]) || [],
                cc: JSON.parse(row[5]) || [],
                subject: row[6],
                source: row[7],
              )
      end
    end
  end

  # Table that act as a dead letter queue of messages.
  class DeadLetterQueueTable
    # @param database [Database] a SQLite Database object
    def initialize(database)
      @database = database
    end

    # Creates the table if not exists.
    #
    # @return [void]
    def create_table
      @database.execute_batch(
        [
          'CREATE TABLE IF NOT EXISTS dead_letter_queue (',
          '  id INTEGER NOT NULL PRIMARY KEY,',
          '  timestamp INTEGER NOT NULL,',
          '  message_id TEXT,',
          '  "from" TEXT NOT NULL,',
          '  "to" TEXT NOT NULL,',
          '  cc TEXT NOT NULL,',
          '  subject TEXT,',
          '  source TEXT',
          ');',
        ].join("\n")
      )
    end

    # Inserts a mail into the queue.
    #
    # @param mail [FetchedMail]
    # @return [void]
    def insert(mail)
      @database.execute(
        [
          'INSERT OR IGNORE INTO dead_letter_queue',
          '  (timestamp, message_id, "from", "to", cc, subject, source)',
          'VALUES',
          '  (?, ?, ?, ?, ?, ?, ?)',
        ].join("\n"),
        [
          mail.timestamp,
          mail.message_id,
          mail.from.to_json,
          mail.to.to_json,
          mail.cc.to_json,
          mail.subject,
          mail.source,
        ]
      )
    end

    # Deletes a mail with the given id from the queue.
    #
    # @param id [String]
    # @return [void]
    def delete(id)
      @database.execute('DELETE FROM dead_letter_queue WHERE ID = ?', [id])
    end

    # Scans queue order by UID in ascending order.
    #
    # @yieldparam mail [DeadLetter]
    # @return [void]
    def scan
      @database.execute(
        [
          'SELECT',
          '  id,',
          '  timestamp,',
          '  message_id,',
          '  "from",',
          '  "to",',
          '  cc,',
          '  subject,',
          '  source',
          'FROM',
          '  dead_letter_queue',
          'ORDER BY',
          '  id',
        ].join("\n")
      ) do |row|
        yield DeadLetter.new(
                id: row[0],
                timestamp: row[1],
                message_id: row[2],
                from: JSON.parse(row[3]) || [],
                to: JSON.parse(row[4]) || [],
                cc: JSON.parse(row[5]) || [],
                subject: row[6],
                source: row[7],
              )
      end
    end
  end
end
