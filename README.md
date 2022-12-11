# `imap-watcher`

Watches on an IMAP server using IDLE command and execute external command on new messages.

## Usage

```sh
bundle install
bundle exec ruby lib/app.rb \
  --server mail.example.org \
  --tls \
  --user me \
  --password 12345 \
  --inbox INBOX \
  --command "jq --exit-status '.subject | contains(\"error\")' && mpv bell.wav"
```

Alternatively, you can store those parameters in `~/.config/imap-watcher/config.json`, or other files specified in `--config` parameter.

Example:

```json
{
  "server": "mail.example.org",
  "tls": true,
  "user": "me",
  "password": "12345",
  "inbox": "INBOX",
  "command": "jq --exit-status '.subject | contains(\"error\")' && mpv bell.wav"
}
```

## Data Format

Mails are passed to the standard input of the command in as a JSON object.

Example (pretty printed for the sake of readability):

```json
{
  "uid": 12345,
  "timestamp": 1672531200,
  "message_id": "0000000@example.org",
  "from": ["test@example.org"],
  "to": ["test@example.org"],
  "cc": [],
  "subject": "test",
  "source": null
}
```

Keys:

- `uid`: IMAP UID of the mail.  Not available for dead letters.
- `timestamp`: The UNIX time of the `Date` header.
- `message_id`: The `Message-ID` header without angle brackets.
- `from`: An array of the `From` header addresses without angle brackets.
- `to`: An array of the `To` header addresses without angle brackets.
- `cc`: An array of the `Cc` header addresses without angle brackets.
- `subject`: The decoded `Subject` header.
- `source`: The entire RFC 5322 message.  Available only if `--fetch-source` is set.

## Command Line Options

- `--config` `PATH`\
  Path to configuration file.\
  Default: $XDG_CONFIG_HOME/imap-watcher/config.json.\
  The configuration file should contain JSON object.\
  Its keys are the command line option names.

- `--server` `SERVER`\
  IMAP server name.

- `--port` `PORT`\
  IMAP Port.\
  Default: 143 for unencrypted server. 993 for encrypted server

- `--user` `USER`\
  User name.

- `--password` `PASSWORD`\
  Password.

- `--command` `COMMAND`\
  Command to execute on mails.  Evalueated by the shell.

- `--dead-letter-command` `COMMAND`\
  Command to execute on dead letters.  Evalueated by the shell.\
  Default: command given by `--command`

- `--mailbox` `MAILBOX`\
  Mailbox to watch.\
  Default: `INBOX`.

- `--fetch-source`\
  Fetch entire RFC 5322 message.

- `--database` `PATH`\
  Path to database.\
  Default: `$XDG_DATA_HOME/imap-watcher/mails.sqlite3`.

- `--tls`\
  Encrypt connection using TLS.\
  Sometimes called SSL.  Not to be confused with `--starttls`.

- `--starttls`\
  Encrypt connection using STARTTLS.\
  Not to be confused with `--tls`.

- `--[no-]verify`\
  Verify server when `--tls` or `--starttls` is used.\
  Default: verify the server.

- `--certificate` `PATH`\
  Path to CA certificate file/directory.

- `--initial-fetch-count` `COUNT`\
  Number of mails to be fetched on the initial startup.\
  Default: 10.\
  Those mails are not passed to the executable.

- `--dead-letter-retry-interval` `COUNT`\
  Interval between re-delivering dead letters, in seconds.\
  Default: 3600.

- `--debug`\
  Show communications between the IMAP server.

- `-h`, `--help`\
  Prints the help.


## Message Delivery Reliability

`imap-watcher` struggles to deliver massage at-least-once.  If `imap-watcher` exits abnormally, it will deliver the mail on the next time.  Nevertheless, it may lose mails if mails are deleted on the server before delivered.

To be precise, If the command returns non-zero exit status, dead letter command given by `--dead-letter-command`, default to the command given by `--command`, is invoked, and if the command returns non-zero exit status again, the mail is queued to the dead letter queue.  Then mails in the dead letter queue will be re-delivered at start up and at intervals of `--dead-letter-retry-interval` seconds.

## Data Stored by `imap-watcher`

A SQLite3 database is created at `~/.local/share/imap-watcher/mails.sqlite3` or any path specified by `--database`.  It contains known message IDs, last known `UID` and `UIDVALIDITY`, and the dead letter queue.


## Developping

```sh
# Run linters.
bundle exec rake lint

# Generate YARD documents.
bundle exec rake doc
```

## License

MIT.  See [LICENSE.md](./LICENSE.md) for details.  Copyright (c) 2023 taku0.
