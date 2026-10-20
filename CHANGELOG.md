# Changelog

## 3.0.0

- `DecodingSettings`: `IntervalDecoding.text` (the server's interval text,
  `'1 day 02:03:04'`), `ExtendedTypeDecoding.text` now also covers `point`
  (`'(1,2)'`), and `nullableArrays: true` makes every array a `List<T?>` (by
  default an array without NULL is a `List<T>` and one with NULL a
  `List<T?>`, so the type of a column changes with its content). Arrays of
  the types decoded as text are `List<String>`.
- Performance: the data type of a column is looked up once, not for every
  value (`typeMap` was a `Map` lookup per value), and text values (`text`,
  `varchar`, `name`, `char(n)`, `"char"`, `xml`) are decoded before any
  other check. `char(n)` had no fast path and went through every check of the
  less common types. A 1000-row result of int/char/timestamp columns decodes
  about 5% faster than 2.8.5.

- **Bug fix**: geometric types (`lseg`, `box`, `line`, `path`, `polygon`,
  `circle`), `bit`/`varbit`, `tsvector`, ranges and their arrays came back as
  their binary bytes or, when those happened to be valid UTF-8, as garbage
  (`'ab'` for the tsvector `'a' 'b'`, `''` for the int4range `[1,5)`). They
  are now the server's text (`'(3,4),(1,2)'`, `'101'`, `"'a' 'b'"`,
  `'[1,5)'`); arrays are lists of texts. Arrays of user-defined types
  (`enum[]`) are the array literal (`'{ok,sad}'`); they were bytes. A
  `tstzrange` bound is printed in UTC (`+00`).

- **Breaking change**: `interval` values (and `interval[]` elements) are now
  always decoded as `PgInterval` (months, days, microseconds; `==`,
  `hashCode`, `toDuration()`, and `toString()` equal to the server's text
  with the default `IntervalStyle` `postgres`). Previously the default was
  `Duration`, and any interval with days or months (`'1 day'`) failed with
  `UnimplementedError`. `DecodingSettings(interval: IntervalDecoding.duration)`
  restores the old behavior. `Duration` and `PgInterval` are both accepted as
  parameters, now also without a type (`@x`, `?`, simple protocol).
- `macaddr`, `macaddr8` (and their arrays) are decoded to the server's
  canonical text (`'08:00:2b:01:02:03'`); previously the binary bytes came
  back as a garbage `String`. `money` (and `money[]`) is decoded to the exact
  amount as a decimal `String` with 2 fraction digits (`'12.34'`, `'-0.05'`,
  `'0.00'`), without the currency symbol; previously the raw bytes. The
  scale of `money` follows `lc_monetary` on the server; 2 is the PostgreSQL
  default for practically all locales. The text path (simple protocol) still
  returns the server's text (for `money`, the locale text, e.g. `R$ 12,34`).
- `oid` and the `reg*` types (`regclass`, `regtype`...), `xid`, `cid`,
  `oid[]`, `oidvector` and `int2vector` (e.g. `pg_index.indkey`) are decoded
  as `int`s; previously a `String` (or `Uint8List`) with the binary bytes.
- **Bug fix**: a connection terminated by the server (`pg_terminate_backend`,
  shutdown) while a query of a `transaction()` was running left that query,
  the transaction's queued queries and the transaction itself waiting for the
  query timeout. All queued callers now fail at once with the server's error
  (`57P01`); callers outside a transaction also get that error instead of a
  generic "connection closing" message.
- **Bug fix**: a transaction queued when the connection was closed produced an
  extra unhandled asynchronous error.
- **Bug fix**: the statement cache was never refreshed: after `ALTER TABLE`
  changed a cached query's result (`0A000`, "cached plan must not change
  result type"), or after the prepared statement was removed (`DEALLOCATE`,
  `DISCARD ALL`, a pooler; `26000`), every later execution of that SQL failed.
  The failing statement is now dropped from the cache (the next execution
  prepares it again), and `DISCARD ALL`/`DEALLOCATE ALL` run on the connection
  clear the cache.
- **Bug fix**: `query()` (with the default `allowReuse`) of a command without
  rows (`INSERT` without `RETURNING`, `UPDATE`, `DELETE`, DDL, `SET`...)
  prepared a new named statement on the server at every call (they were never
  cached), leaking prepared statements.
- **Bug fix**: `query(..., useSimpleQueryProtocol: true)` with several
  statements mixed the rows of all of them with the column description of the
  last one (`toColumnMap()` threw `RangeError`). The result is now the last
  result set, as in libpq (`affectedRowCount` was already the last one's).
- **Bug fix**: `PostgreSQLConnection.settings` was not updated after the
  connection was opened; it now follows `ParameterStatus` messages (`SET
  application_name`, `SET TimeZone`, ...).
- **Bug fix**: non-ASCII column names were decoded byte by byte
  (`"descrição"` came back as `"descriÃ§Ã£o"`), in both APIs.
- **Bug fix**: `mappedResultsQuery` associated table names by position: when
  a result had a column of a view (or another relation that is not a plain
  table) with a smaller OID, the names of the tables were shifted.
- **Bug fix**: `numeric` values between -1 and 0 were decoded without the
  leading zero (`'-0.5'` came back as `'-.5'`).
- **Bug fix**: a `date` parameter (`@d:date`) was encoded from the UTC date,
  truncated towards zero: before 2000 any time after midnight became the next
  day (`1999-12-31 12:00` → `2000-01-01`), and a local `DateTime` could
  become another day. The date of the `DateTime` itself is used (as in the
  text path).
- **Bug fix**: text encoding of parameters and of values written into the SQL
  (untyped `@x`, `?` and the simple protocol):
  - `NaN`/`Infinity` were sent as `'nan'` (with quotes) and rejected (22P02),
    also inside arrays;
  - BC dates were one year off (`DateTime` year -43, i.e. 44 BC, was sent as
    43 BC) and year 0 (1 BC) was rejected;
  - in the SQL text, negative numbers are now parenthesized: `5-@x` with
    `x = -1` became the comment `5--1`, and `@x::int2` with -32768 was out of
    range; `-0.0` keeps its sign (`'-0'::float8`);
  - lists and `PgPoint` written into the SQL were not quoted (syntax error /
    read as a record);
  - `null` elements of lists were not supported: `['a', null]` was sent as
    `{"\"a\"","null"}` (wrong data); they are now `NULL`;
  - `Duration` without a type failed with "Could not infer type".
- **Bug fix**: `@x::type1::type2` (more than one cast after a placeholder)
  became `$1::type1type2`.
- **Bug fix**: the error severity is read from the non-localized `V` field
  (PostgreSQL 9.6+), so `lc_messages` translations (e.g. `FEHLER`, `PÂNICO`)
  no longer make errors `unknown` and `FATAL`/`PANIC` are always recognized.
- **Bug fix**: `PostgreSQLConnection(encoding: ascii)` sent `client_encoding`
  `ascii`, which the server rejects; it now sends `SQL_ASCII`. A server
  message that the connection's encoding cannot decode no longer throws an
  unhandled exception from the socket listener (leaving queries waiting): the
  connection is closed with that error. Error messages that cannot be decoded
  fall back to lenient UTF-8.
- **Bug fix** (v3 experimental API):
  - a query with several statements (`execute('SELECT 1; SELECT 2')`, or DDL
    followed by `INSERT`) threw an unhandled "Future already completed";
    rows of all statements are returned (each with its own schema) and
    `affectedRows` is the last statement's;
  - a parameter that cannot be encoded (e.g. a `String` for an `int`) threw an
    unhandled error and the call never completed (the prepared statement also
    leaked); the call now fails with the `FormatException`;
  - queries without parameters (simple protocol, text format) failed with
    `UnimplementedError` for `date`, `timestamptz`, `numeric`, `uuid`, `json`,
    arrays, `interval` and other types without a text decoder; those values
    are now returned as the server's text;
  - `execute()`/`prepare()` called right before `close()` failed with
    "connection was closed" instead of running first.

- **Bug fix**: a `TZDateTime` (what non-UTC zones decode to) could not be
  sent back as a parameter: the text encoder appended an offset to
  `toIso8601String()`, which already ends with one
  (`'2024-01-15T12:34:56.789123-0300-03:00'`, error 22009). The value is now
  encoded from its fields. Offsets between -01:00 and 00:00 (e.g. -00:30) also
  kept a `+` sign.
- Tests: `non_ascii_connection_strings_test.dart` is skipped with
  `POSTGRES_TEST_NO_DOCKER=1` (it needs its own containers).
- Removed the runtime dependencies `buffer`, `crypto`, `collection`, `sasl_scram`
  (and its transitive `saslprep`/`unorm_dart`), `stream_channel`, `async`,
  `charcode`, `meta`, `pool`, `stack_trace` and `enough_convert`. The needed
  functionality is now implemented in `lib/src/utils` with the same behavior
  (verified by the parity tests in `dependency_parity/`).
- **Breaking change** (v3 experimental API): `PgSessionSettings.transformer` now
  uses the `StreamChannelTransformer`/`StreamSinkTransformer` classes exported by
  `package:postgres_fork/postgres_v3_experimental.dart` instead of the ones from
  `package:stream_channel`/`package:async`.
- The `windows-1252` client encoding is now detected by `Encoding.name`, so any
  codec named `windows-1252` (not only `Windows1252Codec` from `enough_convert`)
  is sent to the server as `WIN1252`.
- Removed the `pg_timezone` dependency. The time zone runtime (`TZDateTime`,
  `Location`, `TimeZone`) is now part of the package and exported by
  `package:postgres_fork/timezone.dart`. The embedded database is generated from
  the IANA tz database (currently 2026e) by `scripts/update_tzdb.dart`, which
  uses a Dart port of the IANA `zic` compiler (`scripts/tzdb/zic.dart`).
- New `TimeZoneSettings.databaseVariant`:
  - `TimeZoneDatabaseVariant.full` (**new default**): all IANA zones and links
    (e.g. `Brazil/East`, `US/Eastern`) with the complete history and explicit
    transitions up to 2100, like PostgreSQL itself.
  - `TimeZoneDatabaseVariant.reduced`: the previous `pg_timezone` database
    (431 common locations, transitions limited to 5 years around the
    generation date).
- **Bug fix**: decoding `timestamptz` with `forceDecodeTimestamptzAsUTC: false`
  could return a value shifted by the daylight saving time difference between
  the value's date and the current date (for example, a January timestamp in
  `America/New_York` decoded during summer came back one hour off). The decoded
  value now always represents the same instant as the server value, with the
  local fields computed using the offset in force at that date. Non-UTC time
  zones now always return a `TZDateTime` (previously zones whose current offset
  was zero returned a UTC `DateTime`).

- Fixes for issue #2 (type decoding and lost connections):
  - A value that cannot be decoded no longer closes the connection: the query
    fails with the decoding error and the connection stays usable (v2 and v3
    APIs, also inside transactions).
  - Arrays: `NULL` elements are decoded as `null` (previously `int[]` with
    `NULL` failed and closed the connection, and `text[]` returned `''`).
    Lists without `NULL` keep the element type (`List<int>`); lists with `NULL`
    are `List<int?>`. Multi-dimensional arrays are decoded as nested lists.
    New array types: `date[]`, `timestamp[]`, `timestamptz[]`, `numeric[]`,
    `int2[]`, `float4[]`, `bytea[]`, `name[]`, `bpchar[]`, `uuid[]`, `json[]`,
    `point[]`, `interval[]`, `time[]`, `timetz[]`, `inet[]` and `cidr[]`.
  - New `DecodingSettings` (`PostgreSQLConnection(decodingSettings: ...)` and
    `PgSessionSettings.decodingSettings`):
    - `interval`: `IntervalDecoding.pgInterval` (**default**, new
      `PgInterval` class with months, days and microseconds) or
      `IntervalDecoding.duration` (the previous `Duration`; intervals with
      months or days throw `UnimplementedError` with an explanatory message).
    - `extendedTypes` for `time`, `timetz`, `inet` and `cidr` (previously raw
      bytes, and `cidr` returned an invalid string):
      `ExtendedTypeDecoding.objects` (**default**: `PgTime`, `PgTimeTz`,
      `PgInet`), `.text` (same text as PostgreSQL) or `.bytes` (raw bytes).
  - `PgInterval`, `PgTime`, `PgTimeTz` and `PgInet` are accepted as query
    parameters (and `PgInterval` for `@x:interval`).
- Authentication fixes:
  - MD5: the hash is now computed over the UTF-8 bytes of the password and the
    user name (as libpq does). Previously non-ASCII passwords failed.
  - SCRAM-SHA-256: passwords rejected by SASLprep (e.g. containing control
    characters) are used as is (as libpq does) instead of throwing.

- New features (v2 API, `PostgreSQLConnection`):
  - `COPY`: `copyFrom(sql, Stream<List<int>>)` (`COPY ... FROM STDIN`, with
    flow control), `copyTo(sql, onData)` (`COPY ... TO STDOUT`) and
    `copyRows(table, columns, rows)`, which writes Dart values in the COPY text
    format (much faster than `INSERT` for many rows). `PgCopy` encodes rows and
    values (`encodeTextRows`, `encodeTextValue`) and decodes text rows
    (`decodeTextRow`). An error in the data stream or in the server aborts the
    COPY (nothing is written) and the connection stays usable. They are also
    available in transactions through an extension on
    `PostgreSQLExecutionContext`. A `COPY ... FROM STDIN` sent through `query`
    or `execute` now fails with a clear error (previously the connection
    hung).
  - Savepoints: `ctx.savepoint((sp) async { ... })` inside `transaction`. An
    error inside the block rolls back only the savepoint
    (`ROLLBACK TO SAVEPOINT`) and is rethrown; the transaction can continue
    and be committed. Savepoints can be nested.
  - Session parameters sent in the startup message: `applicationName` and
    `startupParameters` (e.g. `search_path`, `statement_timeout`), avoiding
    `SET` round trips after connecting (also `PgSessionSettings` in v3).
  - `cancelQuery()` sends a `CancelRequest` (as libpq). With
    `cancelQueryOnTimeout: true`, a query that times out is also cancelled on
    the server, so the connection is released right away.
  - `maxPreparedStatements`: limits the prepared statements kept by the
    connection (least recently used ones are closed on the server). Default:
    no limit (unchanged).
  - `sslMode` (`PgSslMode.disable`, `prefer`, `require`, `verifyFull`). When
    null, `useSSL` decides as before.
  - `listen`, `unlisten`, `notify` and `notificationsFor` for
    `LISTEN`/`NOTIFY`.
  - `DecodingSettings.timestamp`: `TimestampDecoding.localWallClock` decodes
    `timestamp` and `date` as local `DateTime`s with the same fields stored in
    the database.
  - `PgErrorCode` with common SQLSTATE codes (`uniqueViolation`,
    `foreignKeyViolation`, `serializationFailure`, `deadlockDetected`,
    `queryCanceled`, ...) to compare with `PostgreSQLException.code`.
  - `PostgresTextEncodable`: application types can define their own text
    representation for query parameters.
  - Connection pool: `PostgreSQLPool(() => PostgreSQLConnection(...),
    settings: PostgreSQLPoolSettings(...))`, which implements
    `PostgreSQLExecutionContext` and adds `run`, `runTx`, `withConnection`,
    `queryStream`, `copyFrom`/`copyTo`/`copyRows`, `status` and `close`.
    Settings: `maxConnectionCount`, `maxConnectionAge`, `maxSessionUse`,
    `maxErrorCount`, `maxUseCount`, `idleTestThreshold`, `acquireTimeout`,
    `onOpen` and `retryOptions`. Sessions wait in arrival order; a
    connection is closed instead of returned when it was closed, the session
    timed out, a transaction was left open or a limit was reached. Ordinary
    SQL errors do not close the connection.
  - Server-side cursors: `queryStream(sql, fetchSize: ...)` returns the rows
    as a `Stream`, fetched in batches only when the consumer asks for more
    (pausing the subscription stops fetching; cancelling closes the cursor).
    Available on the connection, inside `transaction` and on the pool.
  - `PgDecimal`: arbitrary precision decimal (the `numeric` type, including
    `NaN` and `Infinity`) with the same arithmetic, scale and rounding rules
    as PostgreSQL (verified against the server with random values).
    `DecodingSettings(numeric: NumericDecoding.decimal)` decodes `numeric`
    and `numeric[]` as `PgDecimal` (default: `NumericDecoding.string`,
    unchanged). `PgDecimal` is accepted as a query parameter and in COPY.
- New features (v3 experimental API): `PgSessionExecutor.run` and `runTx`
  (with optional `PgRetryOptions`, which retry on serialization failures and
  deadlocks by default); `PgPool.open` is now implemented (it threw
  `UnimplementedError`; `PgPool.prepare` throws `UnsupportedError`, use
  `withConnection`); `PgConnectionImplementation.isClosed`;
  `TypeMessage.typeName` in logical replication.
- `PgRetryOptions` is exported by both libraries. `PostgreSQLRollback` now
  implements `Exception` (`PostgreSQLPool.runTx` throws it when the
  transaction is cancelled and the return type does not accept it).
- `connection_config.dart` gathers the connection configuration types
  (`PgSslMode`, `ReplicationMode`, `DecodingSettings`, `TimeZoneSettings`);
  `ReplicationMode` is still exported from the same libraries.
- Bug fixes:
  - `execute(timeoutInSeconds: ...)` ignored the given timeout and always used
    the connection's `queryTimeoutInSeconds`.
  - Simple query protocol (`execute`, `useSimpleQueryProtocol: true`): a `NULL`
    value threw an error that closed the connection; it is now `null`.
  - Queries with more than 65535 parameters now fail with a clear error before
    being sent, and the connection stays usable (previously the parameter
    count overflowed and the connection broke).
  - `Uint8List` parameters without a type are sent as `bytea` (hex format)
    instead of being encoded as an array of numbers.
  - In connections that are not in replication mode, `COPY ... TO STDOUT` data
    starting with `k` or `w` was parsed as a replication message (which could
    close the connection).
  - `numeric` values `Infinity` and `-Infinity` (PostgreSQL 14+) were decoded
    as `'0'`; the strings `'Infinity'`/`'-Infinity'` were rejected as typed
    `numeric` parameters.
  - Closing the connection (or losing it) during a transaction left the
    transaction's queries waiting until their timeout, and the rollback then
    waited another 30 seconds; they now fail immediately.
  - v3 API: booleans in results of the simple query protocol (queries
    without parameters) were always `false`.
  - v3 API: when the server closed the connection (e.g.
    `pg_terminate_backend`), the running operation and the next ones never
    completed, the socket error was unhandled and an unsolicited `FATAL`
    error could throw `Bad state: Cannot add event after closing`. They now
    fail with `PostgreSQLException`.
- Fixed a bug inherited from the `buffer` package: when the received byte
  chunks were views of a larger buffer, reading across chunks could read past
  the end of a chunk, losing messages or throwing `RangeError`.
- Performance (measured against 2.8.5, AOT, local PostgreSQL 16): no
  regression in queries, inserts, transactions or decoding (CPU-only decoding
  and encoding benchmarks are ~1% faster); arrays are ~9% faster; SCRAM
  connections ~18% faster; decoding `timestamptz` with a non-UTC time zone is
  ~40x faster (the location lookup is cached until the next zone transition).
- Requires Dart SDK 3.6 (`sdk: ^3.6.0`).

## 2.8.5

- fix decode server Error Response Message

## 2.8.4

- fix decode timestamp without timezone as local DateTime, ignore past timezone transitions

## 2.8.3

- fix init Location By default with UTC 

## 2.8.2

- add more flexibility on how date, timestamp and timestaptz types are decoded by adding flags to the TimeZoneSettings class

## 2.8.1

- change timezone to external pkg
- makes the timeZone parameter of PostgreSQLConnection more flexible to be compatible with String or TimeZoneSettings instance

## 2.8.0

- **Breaking change**: decode timestamp without timezone as local DateTime and decode timestamp with timezone respecting the timezone defined in the connection

- **Breaking change**: timeZone option in PostgreSQLConnection is now a TimeZoneSettings type instead of String

## 2.7.0

- Support has been implemented to change the character encoding for the connection, this makes it possible to change the default encoding from utf8 to win1252, iso8859, among others.

- implemented executing a prepared statement with question mark placeholder style similar to PHP PDO
```dart
 final results = await connection.query(
        ' SELECT * FROM public.table_example LIMIT ?',
        substitutionValues: [2000], placeholderIdentifier: 
        PlaceholderIdentifier.onlyQuestionMark);
```

## 2.6.1

- Added support for bigInt (int8) arrays. [#41](https://github.com/isoos/postgresql-dart/pull/88) by [schultek](https://github.com/schultek).

## 2.6.0

- Updated to `package:lints`.
- Adding lowerCase values to `AuthenticationScheme`.
- Add new `package:postgres/postgres_v3_experimental.dart` library as a preview.
  It exposes the postgres client under a new API that will replace the current
  one in version `3.0.0` of this package.
  At the moment, the new library is experimental and not fully implemented. Until the
  actual `3.0.0` release, the new APIs might change without a breaking version.

## 2.5.2

- Connecting without a password for non-trusted users throws an exception instead of timing out [#68](https://github.com/isoos/postgresql-dart/pull/68) by [osaxma](https://github.com/osaxma).

## 2.5.1

- Use `substitutionValues` with `useSimpleQueryProtocol` [#62](https://github.com/isoos/postgresql-dart/pull/62) by [osaxma](https://github.com/osaxma)

## 2.5.0

- Added Support for Streaming Replication Protocol which included the following changes:
  - Replication Mode Messages Handling. [#58](https://github.com/isoos/postgresql-dart/pull/58) by [osaxma](https://github.com/osaxma)
  - Add new message types for replication. [#57](https://github.com/isoos/postgresql-dart/pull/57) by [osaxma](https://github.com/osaxma)
  - Add connection configuration for Streaming Replication Protocol. [#56](https://github.com/isoos/postgresql-dart/pull/56) by [osaxma](https://github.com/osaxma)
  - Raise the min sdk version to support enhanced enums. [#55](https://github.com/isoos/postgresql-dart/pull/55) by [osaxma](https://github.com/osaxma)
  - Add LSN type and time conversion to and from ms-since-Y2K. [#53](https://github.com/isoos/postgresql-dart/pull/53) by [osaxma](https://github.com/osaxma)
  - Fix affected rows parsing in CommandCompleteMessage. [#52](https://github.com/isoos/postgresql-dart/pull/52) by [osaxma](https://github.com/osaxma)
  - Introduced new APIs to `PostgreSQLConnection`: `addMessage` to send client messages, `messages` stream to listen to server messages & `useSimpleQueryProtocol` option in `query` method. [#51](https://github.com/isoos/postgresql-dart/pull/51) by [osaxma](https://github.com/osaxma)
  
## 2.4.6

- Fix crash when manually issuing a transaction statement like `BEGIN` without
  using the high-level transaction APIs. [#47](https://github.com/isoos/postgresql-dart/pull/47) by [simolus3](https://github.com/simolus3).

## 2.4.5

- Added support for boolean arrays. [#41](https://github.com/isoos/postgresql-dart/pull/41) by [slightfoot](https://github.com/slightfoot).

## 2.4.4

- Added support for varchar arrays. [#39](https://github.com/isoos/postgresql-dart/pull/39) by [paschalisp](https://github.com/paschalisp).

## 2.4.3

- Support for clear text passwords using a boolean parameter in connection as 'allowClearTextPassword' to activate / deactivate the feature. [#20](https://github.com/isoos/postgresql-dart/pull/20).

## 2.4.2

- Include original stacktrace when query fails.
  ([#15](https://github.com/isoos/postgresql-dart/pull/15) by [davidmartos96](https://github.com/davidmartos96))

## 2.4.1+2

- Fix error when sending json data with `execute()` [#11](https://github.com/isoos/postgresql-dart/pull/11)

## 2.4.1+1

- Fix error when passing `allowReuse: null` into `query()` [#8](https://github.com/isoos/postgresql-dart/pull/8)

## 2.4.1

- Support for type `interval`, [#10](https://github.com/isoos/postgresql-dart/pull/10).

## 2.4.0

- Support for type `numeric` / `decimal` ([#7](https://github.com/isoos/postgresql-dart/pull/7), [#9](https://github.com/isoos/postgresql-dart/pull/9)).
- Support SASL / SCRAM-SHA-256 Authentication, [#6](https://github.com/isoos/postgresql-dart/pull/6).

## 2.3.2

- Expose `ColumnDescription.typeId`.

## 2.3.1

- Added support for types `varchar`, `point`, `integerArray`, `doubleArray`, `textArray` and `jsonArray`.
  (Thanks to [schultek](https://github.com/schultek), [#3](https://github.com/isoos/postgresql-dart/pull/3))

## 2.3.0

- Finalized null-safe release.

## 2.3.0-null-safety.2

- Fixing query API optional parameters.

## 2.3.0-null-safety.1

- Updated public API to always return non-nullable results.
- **BREAKING CHANGE**: unknown mapped table name is no longer `null`, it is empty string (`''`).

## 2.3.0-null-safety.0

- Migrate to null safety. (Thanks to [j4qfrost](https://github.com/j4qfrost), [#153](https://github.com/stablekernel/postgresql-dart/pull/153)).
- Documentation fix (by [saward](https://github.com/saward)).

## 2.2.0

- Supporting Unix socket connections. (Thanks to [grillbiff](https://github.com/grillbiff),
  [#124](https://github.com/stablekernel/postgresql-dart/pull/124))
- Preparation for custom type converters.
- Added rowsAffected to PostgreSQLResult. (Thanks to [arturaz](https://github.com/arturaz),
  [#143](https://github.com/stablekernel/postgresql-dart/pull/143))

## 2.1.1

- Fix `RuneIterator.current` use, which no longer returns `null` in 2.8 SDK.

## 2.1.0

- Missing substitution value no longer throws `FormatException`.
  [More details in the GitHub issue.](https://github.com/stablekernel/postgresql-dart/issues/57)

## 2.0.0

- Fixed startup packet length when username is null (#111).
- Finalized dev release.

## 2.0.0-dev1.0

- Restricted field access on [PostgreSQLConnection].
- Connection-level default query timeout.
- Option to specify timeout for the transaction's `"COMMIT"` query.
- Optimized byte buffer parsing and construction with `package:buffer`.
- Hardened codebase with `package:pedantic` and additional lints.
- Updated codebase to Dart 2.2.
- `PostgreSQLResult` and `PostgreSQLResultRow` as the return value of a query.
  - Returned lists are protected with `UnmodifiableListView`.
  - Exposing column metadata through `ColumnDescription`.
  - row-level `toTableColumnMap` and `toColumnMap`
- `PostgreSQLConnection` and `_TransactionProxy` share the OID cache.
- default value for `query(allowReuse = true)` is set only in the implementation method.

**Breaking behaviour**

- Table OIDs are always resolved to table names (and not only with mapped queries).

## 1.0.2
- Add connection queue size

## 1.0.1

- Prevent the table name resolution of OIDs <= 0.

## 1.0.0

- Adds support for Dart 2

## 0.9.9

- Add full support for `UUID` columns.

## 0.9.8

- Preserve error stacktrace on various query or transaction errors.
- Read support for `BYTEA` columns.

## 0.9.7

- Adds `Connection.mappedResultsQuery` to return query results as a `Map` with keys for table and column names.

## 0.9.6

- Adds `Connection.notifications` to listen for `NOTIFY` events (thanks @andrewst)
- Adds better error reporting.
- Adds support for JSONB columns.
- Fixes issue when encoding UTF16 characters (thanks @andrewst)

## 0.9.5

- Allow connect via SSL.

## 0.9.4

- Fixed issue with buffer length

## 0.9.3

- Fixed issue with UTF8 encoding

## 0.9.2

- Bump for documentation

## 0.9.1

- Added transactions: PostgreSQLConnection.transaction and PostgreSQLConnection.cancelTransaction.

## 0.9.0

- Initial version

