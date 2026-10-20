// Regressão do issue #2: decodificação de interval, time, timetz, inet, cidr
// e arrays, e a conexão continua utilizável após falhas de decodificação.

import 'dart:typed_data';

import 'package:postgres_fork/postgres.dart';
import 'package:postgres_fork/postgres_v3_experimental.dart';
import 'package:test/test.dart';

import 'docker.dart';

PostgreSQLConnection _connection(
        [DecodingSettings decoding = const DecodingSettings()]) =>
    PostgreSQLConnection('localhost', 5432, 'dart_test',
        username: 'dart', password: 'dart', decodingSettings: decoding);

Future<PgConnection> _v3([DecodingSettings? decoding]) => PgConnection.open(
      PgEndpoint(
          host: 'localhost',
          database: 'dart_test',
          username: 'dart',
          password: 'dart'),
      sessionSettings: PgSessionSettings(
          onBadSslCertificate: (_) => true, decodingSettings: decoding),
    );

const _intervals = [
  '00:00:00',
  '3 hours',
  '-3 hours',
  '1 day',
  '-1 day',
  '1 mon',
  '1 year 2 mons 3 days 04:05:06.789',
  '-1 year -2 mons +3 days -04:05:06',
  '1 day -01:00:00',
  '-1 day +01:00:00',
  '25:00:00',
  '00:00:00.000001',
  '-00:00:00.5',
  '13 mons',
  '-13 mons 1 day',
  '1000000 hours',
  '178000000 years',
];

const _times = [
  '00:00:00',
  '13:45:10.123456',
  '23:59:59.999999',
  '24:00:00',
  '12:00:00.5',
  '00:00:00.000001',
];

const _timetzs = [
  '13:45:10.5-03',
  '00:00:00+00',
  '12:00:00+05:30',
  '12:00:00-09:30:15',
  '24:00:00-15:59',
  '23:59:59.999999+15:59',
];

const _inets = [
  '192.168.1.10/24',
  '192.168.1.10',
  '0.0.0.0/0',
  '255.255.255.255',
  '::1',
  '::',
  '::2',
  '1::',
  '1::1',
  '2001:db8::/32',
  '2001:db8:0:0:1:0:0:1',
  '2001:0:0:1:0:0:0:1/64',
  '::ffff:1.2.3.4',
  '::1.2.3.4',
  '::ffff:0:1.2.3.4',
  'fe80::1:2:3:4/10',
  'ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff',
  '1:2:3:4:5:6:7:8/128',
  '1:0:0:2:0:0:0:3',
];

const _cidrs = [
  '10.0.0.0/8',
  '10.1.2.3/32',
  '192.168.0.0/16',
  '2001:db8::/32',
  '::/0',
  '::1/128',
];

String _list(List<String> values, String type) =>
    values.map((v) => "('$v'::$type)").join(', ');

void main() {
  usePostgresDocker();

  group('API v2', () {
    late PostgreSQLConnection conn;
    tearDown(() => conn.close());

    Future<void> openWith(DecodingSettings decoding) async {
      conn = _connection(decoding);
      await conn.open();
    }

    Future<void> expectUsable() async {
      expect(await conn.query('SELECT 1'), [
        [1]
      ]);
    }

    test('interval como Duration (opcional); com meses/dias, erro controlado',
        () async {
      await openWith(
          const DecodingSettings(interval: IntervalDecoding.duration));
      expect((await conn.query("SELECT '3 hours'::interval")).first.first,
          const Duration(hours: 3));
      for (final value in ['1 day 02:00:00', '1 mon', '-1 day']) {
        await expectLater(
            conn.query("SELECT '$value'::interval"),
            throwsA(isA<UnimplementedError>().having((e) => e.message,
                'message', contains('IntervalDecoding.pgInterval'))));
        await expectUsable();
      }
    });

    test('interval como PgInterval: valores e texto iguais aos do servidor',
        () async {
      await openWith(
          const DecodingSettings(interval: IntervalDecoding.pgInterval));
      final rows = await conn.query(
          'SELECT v, v::text FROM (VALUES ${_list(_intervals, 'interval')}) t(v)');
      expect(rows, hasLength(_intervals.length));
      for (final row in rows) {
        expect(row[0], isA<PgInterval>());
        expect(row[0].toString(), row[1]);
      }
      final first = rows[6][0] as PgInterval;
      expect(first.months, 14);
      expect(first.days, 3);
      expect(first.microseconds, ((4 * 60 + 5) * 60 + 6) * 1000000 + 789000);
    });

    test('interval como parâmetro (tipado e não tipado)', () async {
      await openWith(
          const DecodingSettings(interval: IntervalDecoding.pgInterval));
      const value =
          PgInterval(months: -14, days: 3, microseconds: -14706000000);
      // O v2 envia "$1" sem tipo; o contexto (CAST) define o tipo no servidor.
      final typed = await conn.query(
          'SELECT CAST(@v:interval AS interval), '
          'CAST(@v:interval AS interval)::text',
          substitutionValues: {'v': value});
      expect(typed.first[0], value);
      expect(typed.first[1], value.toString());
      final untyped = await conn
          .query('SELECT @v::interval', substitutionValues: {'v': value});
      expect(untyped.first[0], value);
      final duration = await conn.query('SELECT CAST(@v:interval AS interval)',
          substitutionValues: {'v': const Duration(minutes: 90)});
      expect(duration.first.first,
          const PgInterval(microseconds: 90 * 60 * 1000000));
    });

    for (final mode in ExtendedTypeDecoding.values) {
      test('time, timetz, inet e cidr no modo ${mode.name}', () async {
        await openWith(DecodingSettings(extendedTypes: mode));
        final cases = {
          'time': _times,
          'timetz': _timetzs,
          'inet': _inets,
          'cidr': _cidrs,
        };
        for (final entry in cases.entries) {
          // format('%s', v) usa a função de saída do tipo (inet::text
          // sempre mostraria a máscara).
          final values = _list(entry.value, entry.key);
          final rows = await conn
              .query("SELECT v, format('%s', v) FROM (VALUES $values) t(v)");
          for (final row in rows) {
            switch (mode) {
              case ExtendedTypeDecoding.objects:
                expect(row[0], isNot(isA<String>()));
                expect(row[0].toString(), row[1], reason: entry.key);
                break;
              case ExtendedTypeDecoding.text:
                expect(row[0], row[1], reason: entry.key);
                break;
              case ExtendedTypeDecoding.bytes:
                expect(row[0], isA<Uint8List>(), reason: entry.key);
                break;
            }
          }
        }
        await expectUsable();
      });
    }

    test('valores dos objetos', () async {
      await openWith(const DecodingSettings());
      final row = (await conn.query("SELECT '13:45:10.123456'::time, "
              "'13:45:10.5-03'::timetz, '192.168.1.10/24'::inet, "
              "'10.0.0.0/8'::cidr"))
          .first;
      final time = row[0] as PgTime;
      expect([time.hour, time.minute, time.second, time.microsecond],
          [13, 45, 10, 123456]);
      final timetz = row[1] as PgTimeTz;
      expect(timetz.time, PgTime(13, 45, 10, 500000));
      expect(timetz.offset, const Duration(hours: -3));
      final inet = row[2] as PgInet;
      expect(inet.address.address, '192.168.1.10');
      expect(inet.prefixLength, 24);
      expect(inet.isCidr, isFalse);
      final cidr = row[3] as PgInet;
      expect(cidr.isCidr, isTrue);
      expect(cidr.prefixLength, 8);
    });

    test('novos tipos como parâmetros não tipados', () async {
      await openWith(const DecodingSettings());
      final values = {
        'a': PgTime(13, 45, 10, 500000),
        'b': PgTimeTz(PgTime(1, 2, 3), -3 * 3600),
        'c': (await conn.query("SELECT '2001:db8::1/64'::inet")).first.first,
        'd': (await conn.query("SELECT '10.0.0.0/8'::cidr")).first.first,
      };
      final row = (await conn.query(
              'SELECT @a::time, @b::timetz, @c::inet, @d::cidr',
              substitutionValues: values))
          .first;
      expect(row, [values['a'], values['b'], values['c'], values['d']]);
    });

    test('arrays com NULL, vários tipos e várias dimensões', () async {
      await openWith(const DecodingSettings());
      final row = (await conn.query('SELECT '
              'ARRAY[1,NULL,3]::int[], '
              'ARRAY[1,2,3]::int[], '
              "ARRAY['2024-01-02'::date, '1999-12-31']::date[], "
              'ARRAY[1.5, 2.25]::numeric[], '
              'ARRAY[1.5, NULL]::numeric[], '
              "ARRAY['a', NULL, '']::text[], "
              'ARRAY[[1,2],[3,4]]::int[], '
              "'{}'::int[], "
              'ARRAY[true, NULL]::bool[], '
              'ARRAY[1.5, -2]::float4[], '
              "ARRAY['2024-01-02 03:04:05+00']::timestamptz[], "
              "ARRAY['a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11']::uuid[], "
              "ARRAY['13:00:00', NULL]::time[], "
              "ARRAY['1.2.3.4/8']::inet[], "
              "ARRAY['1 hour']::interval[], "
              'ARRAY[1, NULL]::int8[], '
              "ARRAY['{\"a\":1}']::jsonb[]"))
          .first;
      expect(row[0], [1, null, 3]);
      expect(row[0], isA<List<int?>>());
      expect(row[1], [1, 2, 3]);
      expect(row[1], isA<List<int>>());
      expect(row[2], [DateTime.utc(2024, 1, 2), DateTime.utc(1999, 12, 31)]);
      expect(row[3], ['1.5', '2.25']);
      expect(row[4], ['1.5', null]);
      expect(row[5], ['a', null, '']);
      expect(row[6], [
        [1, 2],
        [3, 4]
      ]);
      expect(row[7], isEmpty);
      expect(row[8], [true, null]);
      expect(row[9], [1.5, -2.0]);
      expect(row[10], [DateTime.utc(2024, 1, 2, 3, 4, 5)]);
      expect(row[11], ['a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11']);
      expect(row[12], [PgTime(13), null]);
      expect(row[13].toString(), '[1.2.3.4/8]');
      expect(row[14], [const PgInterval(microseconds: 3600000000)]);
      expect(row[15], [1, null]);
      expect(row[16], [
        {'a': 1}
      ]);
    });

    test(
        'a conexão continua utilizável após erro de decodificação dentro '
        'de uma transação', () async {
      await openWith(
          const DecodingSettings(interval: IntervalDecoding.duration));
      await expectLater(conn.transaction((ctx) async {
        await ctx.query("SELECT '1 day'::interval");
      }), throwsA(isA<UnimplementedError>()));
      await expectUsable();
    });
  });

  group('API v3', () {
    // Com parâmetros, a v3 usa o protocolo estendido (resultados binários).
    Future<List<Object?>> binaryRow(PgConnection conn, String columns) async {
      final rows = await conn.execute(
          PgSql('SELECT \$1::int, $columns', types: [PgDataType.integer]),
          parameters: [0]);
      return rows.first.sublist(1);
    }

    test('interval, tipos novos e arrays; conexão continua utilizável',
        () async {
      final conn = await _v3();
      addTearDown(conn.close);
      expect(
          await binaryRow(
              conn,
              "'3 hours'::interval, '13:45:10.5'::time, '10.0.0.0/8'::cidr, "
              'ARRAY[1,NULL,3]::int[], '
              "ARRAY['2024-01-02'::date]::date[]"),
          [
            const PgInterval(microseconds: 3 * 3600000000),
            PgTime(13, 45, 10, 500000),
            isA<PgInet>(),
            [1, null, 3],
            [DateTime.utc(2024, 1, 2)],
          ]);
      expect(await binaryRow(conn, "'1 mon'::interval"),
          [const PgInterval(months: 1)]);
      expect(await conn.execute('SELECT 1'), [
        [1]
      ]);
    });

    test('DecodingSettings na sessão', () async {
      final conn = await _v3(const DecodingSettings(
          interval: IntervalDecoding.pgInterval,
          extendedTypes: ExtendedTypeDecoding.text));
      addTearDown(conn.close);
      expect(
          await binaryRow(conn,
              "'1 mon'::interval, '::1'::inet, ARRAY['1 day']::interval[]"),
          [
            const PgInterval(months: 1),
            '::1',
            [const PgInterval(days: 1)]
          ]);
    });

    test('protocolo simples (texto): booleanos', () async {
      final conn = await _v3();
      addTearDown(conn.close);
      expect(await conn.execute('SELECT true, false, 1 = 1, NULL::bool'), [
        [true, false, true, null]
      ]);
    });

    test('protocolo simples (texto): tipo sem decodificador de texto vira String',
        () async {
      final conn = await _v3();
      addTearDown(conn.close);
      // Antes falhava com UnimplementedError.
      expect(await conn.execute("SELECT '1 mon'::interval"), [
        ['1 mon']
      ]);
      expect(await conn.execute('SELECT 1'), [
        [1]
      ]);
    });
  });
}
