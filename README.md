# postgres

[![CI](https://github.com/insinfo/postgres_fork/actions/workflows/dart.yml/badge.svg)](https://github.com/insinfo/postgres_fork/actions/workflows/dart.yml)
[![Pub Package](https://img.shields.io/pub/v/postgres_fork.svg)](https://pub.dev/packages/postgres_fork)  

postgres fork from https://github.com/isoos/postgresql-dart

- Support has been implemented to change the character encoding for the connection, this makes it possible to change the default encoding from utf8 to win1252, iso8859, among others.

- implemented executing a prepared statement with question mark placeholder style similar to PHP PDO
```dart
 final results = await connection.query(
        ' SELECT * FROM public.table_example LIMIT ?',
        substitutionValues: [2000], placeholderIdentifier: 
        PlaceholderIdentifier.onlyQuestionMark);
```


A library for connecting to and querying PostgreSQL databases (see [Postgres Protocol](https://www.postgresql.org/docs/13/protocol-overview.html)).

This driver uses the more efficient and secure extended query format of the PostgreSQL protocol.

## Usage

Create `PostgreSQLConnection`s and `open` them:

```dart
var connection = PostgreSQLConnection("localhost", 5432, "dart_test", username: "dart", password: "dart");
await connection.open();
```

Execute queries with `query`:

```dart
List<List<dynamic>> results = await connection.query("SELECT a, b FROM table WHERE a = @aValue", substitutionValues: {
    "aValue" : 3
});

for (final row in results) {
  var a = row[0];
  var b = row[1];

} 
```

Return rows as maps containing table and column names:

```dart
List<Map<String, Map<String, dynamic>>> results = await connection.mappedResultsQuery(
  "SELECT t.id, t.name, u.name FROM t LEFT OUTER JOIN u ON t.id=u.t_id");

for (final row in results) {
  var tID = row["t"]["id"];
  var tName = row["t"]["name"];
  var uName = row["u"]["name"];
}
```

Execute queries in a transaction:

```dart
await connection.transaction((ctx) async {
    var result = await ctx.query("SELECT id FROM table");
    await ctx.query("INSERT INTO table (id) VALUES (@a:int4)", substitutionValues: {
        "a" : result.last[0] + 1
    });
});
```

Use savepoints to recover from an error without losing the whole transaction:

```dart
await connection.transaction((ctx) async {
    await ctx.execute("INSERT INTO log (msg) VALUES ('start')");
    try {
        await ctx.savepoint((sp) async {
            await sp.execute("INSERT INTO items (id) VALUES (1)");
        });
    } on PostgreSQLException catch (e) {
        if (e.code != PgErrorCode.uniqueViolation) rethrow;
        // Only the savepoint was rolled back; the transaction continues.
    }
});
```

Bulk insert with `COPY` (much faster than `INSERT` for many rows):

```dart
final count = await connection.copyRows('items', ['id', 'name', 'created'], [
    [1, 'first', DateTime.now()],
    [2, null, DateTime.now()],
]);

// Raw COPY data (text, CSV or binary), sent as it is produced.
await connection.copyFrom('COPY items FROM STDIN WITH (FORMAT csv)', csvBytesStream);

// Export.
await connection.copyTo('COPY items TO STDOUT', (line) {
    print(PgCopy.decodeTextRow(line));
});
```

Connection pool (implements `PostgreSQLExecutionContext`):

```dart
final pool = PostgreSQLPool(
    () => PostgreSQLConnection('localhost', 5432, 'dart_test',
        username: 'dart', password: 'dart', applicationName: 'my-app'),
    settings: const PostgreSQLPoolSettings(maxConnectionCount: 10));

final rows = await pool.query('SELECT * FROM items WHERE id = @id',
    substitutionValues: {'id': 1});
await pool.runTx((ctx) async {
    await ctx.execute('UPDATE items SET qty = qty - 1 WHERE id = 1');
});
await pool.close();
```

Large results as a stream (server-side cursor, fetched on demand):

```dart
await for (final row in connection.queryStream(
        'SELECT * FROM big_table', fetchSize: 1000)) {
    process(row.toColumnMap());
}
```

Exact decimals: `DecodingSettings(numeric: NumericDecoding.decimal)` decodes
`numeric` as `PgDecimal` (arbitrary precision, PostgreSQL arithmetic rules):

```dart
final total = PgDecimal.parse('10.50') * PgDecimal.fromInt(3); // 31.50
```

See the API documentation: https://pub.dev/documentation/postgres/latest/

## Additional Capabilities

The library supports connecting to PostgreSQL using the [Streaming Replication Protocol][].
See [PostgreSQLConnection][] documentation for more info.
An example can also be found at the following repository: [postgresql-dart-replication-example][]

[Streaming Replication Protocol]: https://www.postgresql.org/docs/13/protocol-replication.html
[PostgreSQLConnection]: https://pub.dev/documentation/postgres/latest/postgres/PostgreSQLConnection/PostgreSQLConnection.html
[postgresql-dart-replication-example]: https://github.com/osaxma/postgresql-dart-replication-example

## Features and bugs

This library is a fork of [StableKernel's postgres library](https://github.com/stablekernel/postgresql-dart).

Please file feature requests and bugs at the [issue tracker][tracker].

[tracker]: https://github.com/insinfo/postgres_fork/issues
