// Types without a natural Dart type decode to the server's own text:
// geometric types, bit strings, tsvector, ranges, their arrays, and arrays of
// user-defined types (enum[] as the array literal). They came back as bytes,
// or as garbage when the bytes happened to be valid UTF-8.

import 'package:postgres_fork/postgres.dart';
import 'package:test/test.dart';

import 'docker.dart';

const _scalars = [
  "'[(1,2),(3,4)]'::lseg",
  "'(3,4),(1,2)'::box",
  "'(1.5,-2),(0.1,1e20)'::box",
  "'{1,2,3}'::line",
  "'[(1,2),(3,4),(5,6)]'::path",
  "'((1,2),(3,4),(5,6))'::path",
  "'((0,0),(1,0),(1,1))'::polygon",
  "'<(1,2),3>'::circle",
  "'<(0.001,-0.00001),123456789012345>'::circle",
  "B'101'",
  "B'1010101010101'::varbit",
  "''::varbit",
  "'a b'::tsvector",
  "'fat:2,4A cat:3B rat:5C,6 it''s back\\\\slash'::tsvector",
  "'[1,5)'::int4range",
  "'(1,5]'::int4range",
  "'empty'::int4range",
  "'[,5)'::int4range",
  "'[3,)'::int8range",
  "'[1.5,2.25]'::numrange",
  "'[2024-01-01,2024-02-01)'::daterange",
  "'[2024-01-01 10:00,2024-01-02 00:00:00.5)'::tsrange",
  "'[-infinity,infinity]'::daterange",
];

const _arrays = [
  "array['[(1,2),(3,4)]'::lseg]",
  "array['<(1,2),3>'::circle, null]",
  "array[B'1', B'01']",
  "array['[1,5)'::int4range, 'empty']",
  "array['a'::tsvector]",
];

void main() {
  usePostgresDocker();

  late PostgreSQLConnection conn;
  setUpAll(() async {
    conn = PostgreSQLConnection('localhost', 5432, 'dart_test',
        username: 'dart', password: 'dart', timeZone: 'UTC');
    await conn.open();
    await conn.execute('drop type if exists cov_text_mood cascade');
    await conn
        .execute("create type cov_text_mood as enum ('ok', 'sad', 'a b')");
  });
  tearDownAll(() async {
    await conn.execute('drop type if exists cov_text_mood cascade');
    await conn.close();
  });

  Future<Object?> value(String sql, {bool reuse = true}) async =>
      (await conn.query('select $sql', allowReuse: reuse)).single.single;

  test('scalars are the server text', () async {
    for (final expr in _scalars) {
      final expected = await value('($expr)::text');
      for (final reuse in [false, true, true]) {
        expect(await value(expr, reuse: reuse), expected,
            reason: '$expr (reuse: $reuse)');
      }
    }
  });

  test('arrays are lists of the elements text', () async {
    for (final expr in _arrays) {
      final elements = (await conn.query(
              'select (e)::text from unnest($expr) with ordinality u(e, n) '
              'order by n'))
          .map((row) => row.single)
          .toList();
      expect(await value(expr), elements, reason: expr);
    }
  });

  test('arrays of user-defined types are the array literal', () async {
    for (final expr in [
      "'{ok,sad}'::cov_text_mood[]",
      "array['ok', null, 'a b']::cov_text_mood[]",
      "'{{ok},{sad}}'::cov_text_mood[]",
      "'[0:1]={ok,sad}'::cov_text_mood[]",
      "'{}'::cov_text_mood[]",
    ]) {
      final expected = await value('($expr)::text');
      expect(await value(expr), expected, reason: expr);
    }
    // A scalar enum is still its label.
    expect(await value("'a b'::cov_text_mood"), 'a b');
  });

  test('tstzrange bounds are printed in UTC', () async {
    await conn.execute("set timezone to 'UTC'");
    final expr = "'[2024-01-01 10:00+00,2024-01-02 00:00+00)'::tstzrange";
    expect(await value(expr), await value('($expr)::text'));
  });
}
