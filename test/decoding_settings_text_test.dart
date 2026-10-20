// DecodingSettings(interval: IntervalDecoding.text, extendedTypes:
// ExtendedTypeDecoding.text, nullableArrays: true): the server's text for
// interval, time, timetz, inet, cidr and point (and their arrays), and every
// array as List<T?>.

import 'package:postgres_fork/postgres.dart';
import 'package:test/test.dart';

import 'docker.dart';

void main() {
  usePostgresDocker();

  late PostgreSQLConnection conn;
  setUpAll(() async {
    conn = PostgreSQLConnection('localhost', 5432, 'dart_test',
        username: 'dart',
        password: 'dart',
        decodingSettings: const DecodingSettings(
          interval: IntervalDecoding.text,
          extendedTypes: ExtendedTypeDecoding.text,
          nullableArrays: true,
        ));
    await conn.open();
  });
  tearDownAll(() => conn.close());

  Future<Object?> value(String sql) async =>
      (await conn.query('select $sql')).single.single;

  test('interval, time, timetz, inet, cidr and point are the server text',
      () async {
    for (final expr in [
      "'1 day 02:03:04'::interval",
      "'1 year 2 mons'::interval",
      "'-1 days +02:00:00'::interval",
      "'10:20:30.5'::time",
      "'10:20:30+03'::timetz",
      "'(1,2)'::point",
      "'(1.5,-2.25)'::point",
      "'10.0.0.0/8'::cidr",
    ]) {
      expect(await value(expr), await value('($expr)::text'), reason: expr);
    }
    expect(await value("'10.0.0.1'::inet"), '10.0.0.1');
  });

  test('arrays of these are List<String?>', () async {
    expect(await value("array['1 day'::interval, null]"),
        isA<List<String?>>().having((l) => l, 'value', ['1 day', null]));
    expect(await value("array['(1,2)'::point]"),
        isA<List<String?>>().having((l) => l, 'value', ['(1,2)']));
    expect(await value("array['10:20:30'::time]"),
        isA<List<String?>>().having((l) => l, 'value', ['10:20:30']));
  });

  test('arrays are List<T?> with or without NULL elements', () async {
    expect(await value("'{1,2}'::int4[]"), isA<List<int?>>());
    expect(await value("'{1,NULL}'::int4[]"), isA<List<int?>>());
    expect(await value("'{a,b}'::text[]"), isA<List<String?>>());
    expect(await value("'{1.5}'::numeric[]"), isA<List<String?>>());
    expect(await value("'{2024-01-01}'::date[]"), isA<List<DateTime?>>());
    expect(await value("'{}'::int4[]"), isA<List<int?>>());
  });

  test('the default keeps List<T> for arrays without NULL', () async {
    final plain = PostgreSQLConnection('localhost', 5432, 'dart_test',
        username: 'dart', password: 'dart');
    await plain.open();
    addTearDown(plain.close);
    final list = (await plain.query("select '{1,2}'::int4[]")).single.single;
    expect(list, isA<List<int>>());
  });
}
