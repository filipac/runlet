# TablePlus fixtures (#188)

Made-up TablePlus files for Import from TablePlus…: no real hosts, users, or passwords.

- `Connections.plist`, `ConnectionGroups.plist`: every supported driver (MySQL, MariaDB,
  PostgreSQL, SQLite, SQL Server, Redis since #190, and MongoDB since #209), SSH (key file,
  password, agent; connections sharing one server), TLS, a socket, environment tags, nested
  groups, an unsupported driver (Cassandra), missing and odd fields, an entry that isn't a
  connection, a duplicate name, unknown keys, and a read-only connection.
- MongoDB rows (#209, ids …11 and …19–…25): plain fields; a connection string in
  `DatabaseHost` with a seed list, authentication database, replica set, and read preference;
  SRV; TLS from TablePlus's menu with a CA file; SSH sharing the bastion with two SQL rows; a
  connection string under `DatabaseURL`; a connection string with a made-up password
  (`fixture-tp-Pa55-inventory!`); and SRV over SSH.
- `binary-Connections.plist`: the first three connections as a binary property list.
- `keychain-fixture.json`: the fake Keychain reader's answers (`FakeTablePlusKeychainReader`):
  fixture passwords by TablePlus id, one denied item, one empty item; other ids are missing.
  The item for …24 differs from its connection string's password, so tests can tell which one
  was copied.
- `garbage.plist`, `not-a-list.plist`: files that aren't connection lists.

Debug builds read this folder instead of TablePlus's with `RUNLET_TABLEPLUS_DIR`, and use the
fake reader instead of the Keychain. Regenerate with care: tests and screenshots name these
connections.
