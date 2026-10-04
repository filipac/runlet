# TablePlus fixtures (#188)

Made-up TablePlus files for Import from TablePlus…: no real hosts, users, or passwords.

- `Connections.plist`, `ConnectionGroups.plist`: every supported driver (MySQL, MariaDB,
  PostgreSQL, SQLite, SQL Server), SSH (key file, password, agent; two connections sharing
  one server), TLS, a socket, environment tags, nested groups, unsupported drivers (Redis,
  MongoDB, Cassandra), missing and odd fields, an entry that isn't a connection, a duplicate
  name, unknown keys, and a read-only connection.
- `binary-Connections.plist`: the first three connections as a binary property list.
- `keychain-fixture.json`: the fake Keychain reader's answers (`FakeTablePlusKeychainReader`):
  fixture passwords by TablePlus id, one denied item, one empty item; other ids are missing.
- `garbage.plist`, `not-a-list.plist`: files that aren't connection lists.

Debug builds read this folder instead of TablePlus's with `RUNLET_TABLEPLUS_DIR`, and use the
fake reader instead of the Keychain. Regenerate with care: tests and screenshots name these
connections.
