// Ida e volta de tipos nos dois caminhos do driver: binário (protocolo
// estendido, parâmetros tipados) e texto (parâmetros sem tipo, protocolo
// simples, placeholders '?'). Os dois caminhos precisam concordar entre si e
// com o próprio PostgreSQL.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:postgres_fork/messages.dart';
import 'package:postgres_fork/postgres.dart';
import 'package:postgres_fork/timezone.dart';
import 'package:test/test.dart';

import 'docker.dart';

PostgreSQLConnection _conn(
        {DecodingSettings decoding = const DecodingSettings(),
        Object timeZone = 'UTC',
        Encoding encoding = utf8}) =>
    PostgreSQLConnection('localhost', 5432, 'dart_test',
        username: 'dart',
        password: 'dart',
        decodingSettings: decoding,
        timeZone: timeZone,
        encoding: encoding);

/// Uma expressão SQL e o valor que o decodificador binário deve devolver.
class _Decode {
  const _Decode(this.sql, this.expected);
  final String sql;
  final Object? expected;
}

final _decodes = <_Decode>[
  // Inteiros nos limites.
  const _Decode('32767::int2', 32767),
  const _Decode('(-32768)::int2', -32768),
  const _Decode('2147483647::int4', 2147483647),
  const _Decode('(-2147483648)::int4', -2147483648),
  const _Decode('9223372036854775807::int8', 9223372036854775807),
  const _Decode('(-9223372036854775808)::int8', -9223372036854775808),
  // Ponto flutuante.
  const _Decode("'Infinity'::float8", double.infinity),
  const _Decode("'-Infinity'::float8", double.negativeInfinity),
  const _Decode('0.1::float8', 0.1),
  const _Decode('1e308::float8', 1e308),
  const _Decode('1.5::float4', 1.5),
  const _Decode("'Infinity'::float4", double.infinity),
  // Outros escalares.
  const _Decode('true', true),
  const _Decode('false', false),
  const _Decode("'çãé漢字😀'::text", 'çãé漢字😀'),
  const _Decode("''::text", ''),
  const _Decode("'ab'::char(4)", 'ab  '),
  const _Decode("'xyz'::name", 'xyz'),
  const _Decode("'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid",
      'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'),
  // JSON: objetos, arrays e escalares.
  const _Decode('\'{"a":[1,2,null]}\'::json', {
    'a': [1, 2, null]
  }),
  const _Decode('\'[1,"x"]\'::jsonb', [1, 'x']),
  const _Decode('\'"str"\'::jsonb', 'str'),
  const _Decode("'null'::jsonb", null),
  const _Decode("'42'::json", 42),
  const _Decode("'true'::jsonb", true),
  // Datas: a.C., ano 0 do DateTime (= 1 a.C.), anos > 9999, infinito.
  _Decode("'2024-01-15'::date", DateTime.utc(2024, 1, 15)),
  _Decode("'0001-01-01 BC'::date", DateTime.utc(0, 1, 1)),
  _Decode("'4713-01-01 BC'::date", DateTime.utc(-4712, 1, 1)),
  _Decode("'10000-01-01'::date", DateTime.utc(10000, 1, 1)),
  const _Decode("'infinity'::date", null),
  const _Decode("'-infinity'::date", null),
  _Decode("'2024-01-15 12:34:56.123456'::timestamp",
      DateTime.utc(2024, 1, 15, 12, 34, 56, 123, 456)),
  _Decode("'2024-01-15 12:34:56.000001'::timestamp",
      DateTime.utc(2024, 1, 15, 12, 34, 56, 0, 1)),
  _Decode("'0044-03-15 12:00 BC'::timestamp", DateTime.utc(-43, 3, 15, 12)),
  _Decode(
      "'12345-06-07 08:09:10'::timestamp", DateTime.utc(12345, 6, 7, 8, 9, 10)),
  const _Decode("'infinity'::timestamp", null),
  _Decode("'2024-01-15 12:34:56.5+00'::timestamptz",
      DateTime.utc(2024, 1, 15, 12, 34, 56, 500)),
  _Decode("'0001-01-01 00:00+00 BC'::timestamptz", DateTime.utc(0, 1, 1)),
  const _Decode("'-infinity'::timestamptz", null),
  // time, timetz, interval, inet, cidr, point.
  _Decode("'13:45:10.123456'::time", PgTime(13, 45, 10, 123456)),
  const _Decode("'24:00'::time", PgTime.fromMicroseconds(86400000000)),
  const _Decode(
      "'3 hours'::interval", PgInterval(microseconds: 3 * 3600000000)),
  const _Decode("'-00:00:00.000001'::interval", PgInterval(microseconds: -1)),
  const _Decode("'1 day'::interval", PgInterval(days: 1)),
  const _Decode("'-1 mon'::interval", PgInterval(months: -1)),
  const _Decode(
      "'{\"1 mon\",NULL}'::interval[]", [PgInterval(months: 1), null]),
  // macaddr, macaddr8 e money (antes Strings com os bytes, ou os bytes).
  const _Decode("'08-00-2B-01-02-03'::macaddr", '08:00:2b:01:02:03'),
  const _Decode(
      "'08:00:2b:01:02:03:04:05'::macaddr8", '08:00:2b:01:02:03:04:05'),
  const _Decode(
      "'{08:00:2b:01:02:03,NULL}'::macaddr[]", ['08:00:2b:01:02:03', null]),
  const _Decode(
      "'{08:00:2b:01:02:03:04:05}'::macaddr8[]", ['08:00:2b:01:02:03:04:05']),
  const _Decode('12.34::numeric::money', '12.34'),
  const _Decode('(-0.05)::numeric::money', '-0.05'),
  const _Decode('0::numeric::money', '0.00'),
  const _Decode('92233720368547758.07::numeric::money', '92233720368547758.07'),
  const _Decode(
      '(-92233720368547758.08)::numeric::money', '-92233720368547758.08'),
  const _Decode('ARRAY[1::numeric::money, NULL]', ['1.00', null]),
  const _Decode("'(1.5,2)'::point", PgPoint(1.5, 2)),
  // Arrays: NULL, várias dimensões, limites explícitos, vazio, 'null' como
  // texto, NaN/Infinity, json[] e infinito.
  const _Decode("'{1,NULL,3}'::int[]", [1, null, 3]),
  const _Decode("'{{1,2},{3,4}}'::int[]", [
    [1, 2],
    [3, 4]
  ]),
  // Os limites explícitos não fazem parte da lista Dart.
  const _Decode("'[0:1]={1,2}'::int[]", [1, 2]),
  const _Decode("'{}'::int[]", <int>[]),
  const _Decode("'{NULL}'::text[]", [null]),
  const _Decode(
      '\'{"null",NULL,"a,b",""}\'::text[]', ['null', null, 'a,b', '']),
  const _Decode("'{NaN,1.5}'::numeric[]", ['NaN', '1.5']),
  const _Decode('ARRAY[\'{"a":1}\'::json, NULL]', [
    {'a': 1},
    null
  ]),
  const _Decode("ARRAY['null'::jsonb, '[1]'::jsonb, NULL]", [
    null,
    [1],
    null
  ]),
  _Decode("'{2024-01-01,infinity}'::date[]", [DateTime.utc(2024), null]),
  const _Decode("'{t,f,NULL}'::bool[]", [true, false, null]),
  const _Decode("'{{{1}},{{2}}}'::int8[]", [
    [
      [1]
    ],
    [
      [2]
    ]
  ]),
  const _Decode("'{1.5,2.5}'::float4[]", [1.5, 2.5]),
  const _Decode("'{1,-32768}'::int2[]", [1, -32768]),
  const _Decode("'{a,NULL}'::varchar[]", ['a', null]),
  const _Decode("'{a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11}'::uuid[]",
      ['a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11']),
  _Decode("'{2024-01-15 12:00:00+00,NULL}'::timestamptz[]",
      [DateTime.utc(2024, 1, 15, 12), null]),
  // oid e tipos derivados (antes uma String com os bytes).
  const _Decode('12::oid', 12),
  const _Decode("'pg_class'::regclass", 1259),
  const _Decode("'int4'::regtype", 23),
  const _Decode("'4294967295'::oid", 4294967295),
  const _Decode("'{1,2}'::oid[]", [1, 2]),
  const _Decode("'1 2'::int2vector", [1, 2]),
  const _Decode("'23 25'::oidvector", [23, 25]),
];

/// O mesmo valor enviado por cada caminho: tipado (`@v:tipo`, binário),
/// sem tipo (`@v`, texto), no texto do SQL (protocolo simples) e com '?'.
class _Param {
  const _Param(this.cast, this.value, this.expected,
      {this.typed, this.untyped = true});
  final String cast;
  final Object? value;
  final String? expected;

  /// Tipo do placeholder tipado (null: o caminho tipado não se aplica).
  final String? typed;

  /// Se o valor é aceito sem tipo (JSON que não é um Map é ambíguo).
  final bool untyped;
}

final _quotes = String.fromCharCodes([39, 34, 92]); // ' " \

final _params = <_Param>[
  const _Param('int2', -32768, '-32768', typed: 'int2'),
  const _Param('int4', 2147483647, '2147483647', typed: 'int4'),
  const _Param('int8', -9223372036854775808, '-9223372036854775808',
      typed: 'int8'),
  const _Param('int4', -1, '-1', typed: 'int4'),
  const _Param('float8', double.nan, 'NaN', typed: 'float8'),
  const _Param('float8', double.infinity, 'Infinity', typed: 'float8'),
  const _Param('float8', double.negativeInfinity, '-Infinity', typed: 'float8'),
  const _Param('float8', 0.1, '0.1', typed: 'float8'),
  const _Param('float8', -0.0, '-0', typed: 'float8'),
  const _Param('float8', 1e-300, '1e-300', typed: 'float8'),
  const _Param('float4', 1.5, '1.5', typed: 'float4'),
  const _Param('float4', double.nan, 'NaN', typed: 'float4'),
  const _Param('numeric', '-0.0000001', '-0.0000001', typed: 'numeric'),
  const _Param('numeric', '123456789012345678901234567890.000000001',
      '123456789012345678901234567890.000000001',
      typed: 'numeric'),
  const _Param('numeric', 'NaN', 'NaN', typed: 'numeric'),
  const _Param('numeric', 1.5, '1.5', typed: 'numeric'),
  const _Param('numeric', 10000, '10000', typed: 'numeric'),
  const _Param('numeric', '0.00010000', '0.00010000', typed: 'numeric'),
  const _Param('bool', true, 'true', typed: 'boolean'),
  _Param('text', 'çã$_quotes漢😀', 'çã$_quotes漢😀', typed: 'text'),
  const _Param('text', '', '', typed: 'text'),
  const _Param('text', null, null, typed: 'text'),
  _Param('bytea', Uint8List.fromList([0, 255, 10, 92, 39]), r'\x00ff0a5c27',
      typed: 'bytea'),
  const _Param('uuid', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11',
      'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11',
      typed: 'uuid'),
  _Param(
      'jsonb',
      {
        'a': [1, null, 'x$_quotes']
      },
      '{"a": [1, null, "x\'\\"\\\\"]}',
      typed: 'jsonb'),
  const _Param('jsonb', [1, 2], '[1, 2]', typed: 'jsonb', untyped: false),
  const _Param('json', 'str', '"str"', typed: 'json', untyped: false),
  const _Param('jsonb', 42, '42', typed: 'jsonb', untyped: false),
  // Datas: antes de 2000 com horário, ano 0 (= 1 a.C.), a.C., > 9999.
  _Param('date', DateTime.utc(2024, 1, 15), '2024-01-15', typed: 'date'),
  _Param('date', DateTime.utc(1999, 12, 31, 12), '1999-12-31', typed: 'date'),
  _Param('date', DateTime.utc(0, 1, 1), '0001-01-01 BC', typed: 'date'),
  _Param('date', DateTime.utc(-43, 3, 15), '0044-03-15 BC', typed: 'date'),
  _Param('date', DateTime.utc(12345, 6, 7), '12345-06-07', typed: 'date'),
  _Param('timestamp', DateTime.utc(2024, 1, 15, 12, 34, 56, 0, 1),
      '2024-01-15 12:34:56.000001',
      typed: 'timestamp'),
  _Param('timestamp', DateTime.utc(2024, 1, 15, 12, 34, 56, 7),
      '2024-01-15 12:34:56.007',
      typed: 'timestamp'),
  _Param('timestamp', DateTime.utc(-43, 3, 15, 12), '0044-03-15 12:00:00 BC',
      typed: 'timestamp'),
  _Param('timestamp', DateTime.utc(0, 6, 1), '0001-06-01 00:00:00 BC',
      typed: 'timestamp'),
  _Param(
      'timestamp', DateTime.utc(12345, 6, 7, 8, 9, 10), '12345-06-07 08:09:10',
      typed: 'timestamp'),
  _Param('timestamptz', DateTime.utc(2024, 1, 15, 12, 34, 56, 123, 456),
      '2024-01-15 12:34:56.123456+00',
      typed: 'timestamptz'),
  _Param('timestamptz', DateTime.utc(1999, 12, 31, 23, 59, 59, 999, 999),
      '1999-12-31 23:59:59.999999+00',
      typed: 'timestamptz'),
  _Param('timestamptz', DateTime.utc(0, 6, 1), '0001-06-01 00:00:00+00 BC',
      typed: 'timestamptz'),
  // interval: Duration (o tipo que o decodificador devolve) e PgInterval.
  const _Param(
      'interval', Duration(hours: 3, microseconds: 5), '03:00:00.000005',
      typed: 'interval'),
  const _Param('interval', Duration(microseconds: -1), '-00:00:00.000001',
      typed: 'interval'),
  const _Param('interval', PgInterval(months: 1, days: 2, microseconds: 3),
      '1 mon 2 days 00:00:00.000003',
      typed: 'interval'),
  // Arrays.
  const _Param('int4[]', [1, 2, 3], '{1,2,3}', typed: '_int4'),
  const _Param('int8[]', [9223372036854775807], '{9223372036854775807}',
      typed: '_int8'),
  _Param('text[]', ['a', 'b,c', '"q"', _quotes, 'null', ''],
      '{a,"b,c","\\"q\\"","\'\\"\\\\","null",""}',
      typed: '_text'),
  const _Param(
      'float8[]', [1.5, double.nan, double.infinity], '{1.5,NaN,Infinity}',
      typed: '_float8'),
  const _Param('bool[]', [true, false], '{t,f}', typed: '_bool'),
  const _Param(
      'jsonb[]',
      [
        {'a': 1},
        [1],
        'x'
      ],
      '{"{\\"a\\": 1}",[1],"\\"x\\""}',
      typed: '_jsonb'),
  const _Param('varchar[]', ['x', 'y'], '{x,y}', typed: '_varchar'),
  // NULL nos arrays (só sem tipo: o codificador binário exige List<int>).
  const _Param('int4[]', [1, null, 3], '{1,NULL,3}'),
  const _Param('text[]', ['a', null, 'null'], '{a,NULL,"null"}'),
  const _Param('text[]', [null], '{NULL}'),
  const _Param('point', PgPoint(1.5, -2), '(1.5,-2)', typed: 'point'),
  _Param('time', PgTime(13, 45, 10, 123456), '13:45:10.123456'),
  _Param('inet', PgInet(InternetAddress('10.0.0.1'), 8), '10.0.0.1/8'),
];

String _two(int n) => n.toString().padLeft(2, '0');

void main() {
  usePostgresDocker();

  group('decodificação binária', () {
    late PostgreSQLConnection c;

    setUpAll(() async {
      c = _conn();
      await c.open();
    });

    tearDownAll(() => c.close());

    for (final d in _decodes) {
      test(d.sql, () async {
        for (final reuse in [true, false, true]) {
          final r = await c.query('SELECT ${d.sql} AS v', allowReuse: reuse);
          expect(r.single.single, d.expected);
        }
      });
    }

    test('NaN e -0.0', () async {
      final r = await c.query(
          "SELECT 'NaN'::float8, 'NaN'::float4, '-0'::float8, 'NaN'::numeric");
      expect((r.single[0] as double).isNaN, isTrue);
      expect((r.single[1] as double).isNaN, isTrue);
      expect((r.single[2] as double).isNegative, isTrue);
      expect(r.single[3], 'NaN');
    });

    test('bytea', () async {
      final r = await c.query(r"SELECT '\x00ff0a'::bytea, ''::bytea");
      expect(r.single[0], [0, 255, 10]);
      expect(r.single[1], isA<Uint8List>().having((b) => b.length, 'len', 0));
    });

    test('numeric: valor exato igual ao texto do servidor', () async {
      // Regressão: '-0.0000001' (e qualquer negativo entre -1 e 0) vinha
      // como '-.0000001'.
      const values = [
        '123456789012345678901234567890.123456789',
        '-0.0000001',
        '-0.5',
        '-12.50',
        '0.00',
        '-0.00',
        '10000',
        '-10000.0001',
        '1e-20',
        '-1e-20',
        '99999999999999999999',
        'Infinity',
        '-Infinity',
      ];
      for (final v in values) {
        final r = await c.query("SELECT '$v'::numeric, '$v'::numeric::text");
        expect(r.single[0], r.single[1], reason: v);
      }
      final decimal = _conn(
          decoding: const DecodingSettings(numeric: NumericDecoding.decimal));
      await decimal.open();
      addTearDown(decimal.close);
      for (final v in values) {
        final r =
            await decimal.query("SELECT '$v'::numeric, '$v'::numeric::text");
        expect(r.single[0].toString(), r.single[1], reason: v);
      }
    });

    test('time, timetz, inet e cidr', () async {
      final r = await c.query("SELECT '13:45:10-03'::timetz, "
          "'192.168.1.1'::inet, '10.0.0.0/8'::cidr, '2001:db8::1/64'::inet, "
          "'::1/128'::inet, '{1.1.1.1,NULL}'::inet[]");
      expect(r.single.map((v) => '$v').toList(), [
        '13:45:10-03',
        '192.168.1.1',
        '10.0.0.0/8',
        '2001:db8::1/64',
        '::1',
        '[1.1.1.1, null]',
      ]);
    });

    test('interval: PgInterval (padrão) com o texto igual ao do servidor',
        () async {
      // Antes (padrão Duration) intervalos com dias ou meses lançavam
      // UnimplementedError.
      const values = [
        '00:00:00',
        '1 day 02:03:04',
        '1 year 2 mons',
        '-1 days +02:00:00',
        '3 days',
        '1 year 2 mons 3 days 04:05:06.789',
        '1 year',
        '2 years 1 mon',
        '1 day',
        '-1 day',
        '-1 year -2 mons +3 days -04:05:06',
        '1 day -01:00:00',
        '-00:00:00.5',
        '00:00:00.000001',
        '25:00:00',
        '-13 mons 1 day',
        '178000000 years',
        '1 mon -1 days',
        '-1 mons',
        '10:20:30.120000',
      ];
      for (final v in values) {
        final r = await c.query("SELECT '$v'::interval, '$v'::interval::text");
        expect(r.single[0], isA<PgInterval>(), reason: v);
        expect(r.single[0].toString(), r.single[1], reason: v);
        // E volta como parâmetro pelos dois caminhos.
        final back = await c.query(
            'SELECT @a:interval::interval = @b::interval::interval',
            substitutionValues: {'a': r.single[0], 'b': r.single[0]});
        expect(back.single.single, isTrue, reason: v);
        expect(
            (await c.query("SELECT @a::interval = '$v'::interval",
                    substitutionValues: {'a': r.single[0]}))
                .single
                .single,
            isTrue,
            reason: v);
      }
      final day = (await c.query("SELECT '1 day 02:00:00'::interval"))
          .single
          .single as PgInterval;
      expect(day.toDuration(), const Duration(days: 1, hours: 2));
      final mon = (await c.query("SELECT '1 mon'::interval")).single.single
          as PgInterval;
      expect(mon.toDuration, throwsStateError);
      // O protocolo simples devolve o texto do servidor (igual ao toString).
      expect(
          await c.query("SELECT '1 day'::interval",
              useSimpleQueryProtocol: true),
          [
            ['1 day']
          ]);
      // O modo Duration continua disponível (com erro controlado).
      final legacy = _conn(
          decoding:
              const DecodingSettings(interval: IntervalDecoding.duration));
      await legacy.open();
      addTearDown(legacy.close);
      expect((await legacy.query("SELECT '3 hours'::interval")).single.single,
          const Duration(hours: 3));
      await expectLater(legacy.query("SELECT '1 day'::interval"),
          throwsA(isA<UnimplementedError>()));
      expect(await legacy.query('SELECT 1'), [
        [1]
      ]);
    });

    test('money e macaddr: iguais ao texto do servidor', () async {
      for (final v in ['12.34', '-0.05', '0', '1000000.1', '-1']) {
        final r = await c.query(
            'SELECT ($v)::numeric::money, ($v)::numeric::money::numeric::text');
        expect(r.single[0], r.single[1], reason: v);
      }
      for (final v in [
        '08:00:2b:01:02:03',
        'ff:ff:ff:ff:ff:ff',
        '00:00:00:00:00:00'
      ]) {
        final r = await c.query("SELECT '$v'::macaddr, '$v'::macaddr::text, "
            "'$v'::macaddr::macaddr8, '$v'::macaddr::macaddr8::text");
        expect(r.single[0], r.single[1]);
        expect(r.single[2], r.single[3]);
        expect(
            await c.query("SELECT '$v'::macaddr", useSimpleQueryProtocol: true),
            [
              [r.single[1]]
            ]);
      }
    });

    test('time, timetz, inet e cidr: toString igual ao texto do servidor',
        () async {
      const values = {
        'time': [
          '10:20:30.5',
          '00:00:00',
          '23:59:59.999999',
          '24:00:00',
          '10:20:30.000001'
        ],
        'timetz': [
          '10:20:30+03',
          '10:20:30+05:30',
          '10:20:30-09:30:15',
          '00:00:00+00',
          '10:20:30.5-03'
        ],
        'inet': [
          '192.168.1.5',
          '192.168.1.5/32',
          '192.168.1.5/24',
          '0.0.0.0/0',
          '::1',
          '::1/128',
          '2001:db8::1/64',
          '::ffff:1.2.3.4',
          '1:2:3:4:5:6:7:8',
          '1::8',
          'fe80::',
          '1:0:0:2::3',
        ],
        'cidr': [
          '10.0.0.0/8',
          '192.168.1.5/32',
          '::/0',
          '2001:db8::/32',
          '::1/128',
        ],
      };
      for (final entry in values.entries) {
        for (final v in entry.value) {
          final type = entry.key;
          // Comparado com a saída do tipo (protocolo simples): o cast
          // inet::text sempre inclui a máscara ('/32'), a saída não.
          final binary = await c.query("SELECT '$v'::$type");
          final text =
              await c.query("SELECT '$v'::$type", useSimpleQueryProtocol: true);
          expect(binary.single.single.toString(), text.single.single,
              reason: '$type $v');
        }
      }
    });

    test('enum, domínio e composto', () async {
      await c.execute('DROP TABLE IF EXISTS cov_types_t');
      await c.execute('DROP TYPE IF EXISTS cov_types_mood');
      await c.execute('DROP DOMAIN IF EXISTS cov_types_pos');
      await c.execute('DROP TYPE IF EXISTS cov_types_pair');
      addTearDown(() async {
        final cleanup = _conn();
        await cleanup.open();
        await cleanup.execute('DROP TABLE IF EXISTS cov_types_t');
        await cleanup.execute('DROP TYPE IF EXISTS cov_types_mood');
        await cleanup.execute('DROP DOMAIN IF EXISTS cov_types_pos');
        await cleanup.execute('DROP TYPE IF EXISTS cov_types_pair');
        await cleanup.close();
      });
      await c.execute("CREATE TYPE cov_types_mood AS ENUM ('feliz', 'triste')");
      await c.execute('CREATE DOMAIN cov_types_pos AS int CHECK (VALUE > 0)');
      await c.execute('CREATE TYPE cov_types_pair AS (a int, b text)');
      await c.execute('CREATE TABLE cov_types_t (m cov_types_mood, '
          'p cov_types_pos, c cov_types_pair, ms cov_types_mood[])');
      await c.query('INSERT INTO cov_types_t VALUES (@m, @p, @c, @ms)',
          substitutionValues: {
            'm': 'feliz',
            'p': 5,
            'c': '(1,x)',
            'ms': '{feliz,triste}',
          });
      // enum: o formato binário é o rótulo; domínio: o tipo base.
      final r = await c.query('SELECT m, p, ms::text[], c::text, '
          '(c).a, (c).b FROM cov_types_t');
      expect(r.single, [
        'feliz',
        5,
        ['feliz', 'triste'],
        '(1,x)',
        1,
        'x'
      ]);
      // Limitação: compostos e arrays de tipos criados pelo usuário não
      // têm decodificador binário (use ::text); a conexão continua ok.
      final raw = await c.query('SELECT c, ms FROM cov_types_t');
      expect(raw.single, hasLength(2));
      expect(await c.query('SELECT 1'), [
        [1]
      ]);
      // Domínio violado: erro do servidor, conexão ok.
      await expectLater(
          c.query('INSERT INTO cov_types_t (p) VALUES (@p)',
              substitutionValues: {'p': -1}),
          throwsA(isA<PostgreSQLException>()
              .having((e) => e.code, 'code', PgErrorCode.checkViolation)));
      expect(await c.query('SELECT 2'), [
        [2]
      ]);
    });
  });

  group('parâmetros: tipado, sem tipo, protocolo simples e ?', () {
    late PostgreSQLConnection c;

    setUpAll(() async {
      c = _conn();
      await c.open();
    });

    tearDownAll(() => c.close());

    for (final p in _params) {
      test('${p.cast} ${p.value is Uint8List ? 'bytes' : p.value}', () async {
        Future<Object?> text(String sql, Object values,
                {bool simple = false,
                PlaceholderIdentifier placeholder =
                    PlaceholderIdentifier.atSign}) async =>
            (await c.query(sql,
                    substitutionValues: values,
                    useSimpleQueryProtocol: simple,
                    placeholderIdentifier: placeholder))
                .single
                .single;

        final typed = p.typed;
        if (typed != null) {
          expect(
              await text('SELECT (@v:$typed::${p.cast})::text', {'v': p.value}),
              p.expected,
              reason: 'tipado');
        }
        if (!p.untyped) return;
        expect(await text('SELECT (@v::${p.cast})::text', {'v': p.value}),
            p.expected,
            reason: 'sem tipo');
        expect(
            await text('SELECT (@v::${p.cast})::text', {'v': p.value},
                simple: true),
            p.expected,
            reason: 'protocolo simples');
        expect(
            await text('SELECT (?::${p.cast})::text', [p.value],
                placeholder: PlaceholderIdentifier.onlyQuestionMark),
            p.expected,
            reason: '?');
      });
    }

    test('date com DateTime local usa a data do próprio valor', () async {
      // Antes o caminho binário usava a data em UTC: num fuso negativo, um
      // horário à noite virava o dia seguinte (o caminho texto não).
      final local = DateTime(2024, 1, 15, 23, 30);
      final r = await c.query('SELECT @a:date::date::text, @b::date::text',
          substitutionValues: {'a': local, 'b': local});
      expect(r.single, ['2024-01-15', '2024-01-15']);
    });

    test('valores lidos voltam como parâmetros', () async {
      final row = (await c.query("SELECT '0044-03-15 BC'::date, "
              "'0001-01-01 12:00 BC'::timestamp, '3 hours'::interval, "
              "'-0.5'::numeric, '{1,NULL}'::int[], 'NaN'::float8"))
          .single;
      final back = await c.query(
          'SELECT @d::date = \'0044-03-15 BC\'::date, '
          "@t::timestamp = '0001-01-01 12:00 BC'::timestamp, "
          "@i::interval = '3 hours'::interval, "
          "@n::numeric = '-0.5'::numeric, "
          "@a::int[] IS NOT DISTINCT FROM '{1,NULL}'::int[], "
          "@f::float8 = 'NaN'::float8",
          substitutionValues: {
            'd': row[0],
            't': row[1],
            'i': row[2],
            'n': row[3],
            'a': row[4],
            'f': row[5],
          });
      expect(back.single, [true, true, true, true, true, true]);
    });
  });

  group('fusos horários', () {
    Future<PostgreSQLConnection> open(String zone) async {
      final conn = _conn(
          timeZone: TimeZoneSettings(zone, forceDecodeTimestamptzAsUTC: false));
      await conn.open();
      addTearDown(conn.close);
      return conn;
    }

    // Instantes em volta das mudanças de horário de verão.
    final instants = {
      'America/Sao_Paulo': [
        DateTime.utc(2018, 11, 4, 2, 59, 59, 999, 999),
        DateTime.utc(2018, 11, 4, 3),
        DateTime.utc(2019, 2, 17, 1, 59, 59),
        DateTime.utc(2019, 2, 17, 2),
        DateTime.utc(2024, 1, 15, 12, 34, 56, 123, 456),
      ],
      'America/New_York': [
        DateTime.utc(2024, 3, 10, 6, 59, 59),
        DateTime.utc(2024, 3, 10, 7),
        DateTime.utc(2024, 11, 3, 5, 59, 59),
        DateTime.utc(2024, 11, 3, 6),
        DateTime.utc(1950, 7, 1, 12),
      ],
    };

    for (final entry in instants.entries) {
      test('${entry.key}: campos locais iguais aos do servidor e ida e volta',
          () async {
        final conn = await open(entry.key);
        for (final instant in entry.value) {
          final r = await conn.query(
              'SELECT @t:timestamptz::timestamptz, '
              "to_char(@t:timestamptz::timestamptz, 'YYYY-MM-DD HH24:MI:SS.US'), "
              'extract(timezone FROM @t:timestamptz::timestamptz)::int',
              substitutionValues: {'t': instant});
          final value = r.single[0] as DateTime;
          expect(value, isA<TZDateTime>());
          expect(value.isAtSameMomentAs(instant), isTrue);
          final fields =
              '${value.year}-${_two(value.month)}-${_two(value.day)} '
              '${_two(value.hour)}:${_two(value.minute)}:${_two(value.second)}.'
              '${(value.millisecond * 1000 + value.microsecond).toString().padLeft(6, '0')}';
          expect(fields, r.single[1], reason: '$instant');
          expect(value.timeZoneOffset.inSeconds, r.single[2],
              reason: '$instant');
          // O TZDateTime lido volta como parâmetro pelos dois caminhos.
          final back = await conn.query(
              'SELECT @a:timestamptz::timestamptz = @t:timestamptz::timestamptz, '
              '@a::timestamptz = @t:timestamptz::timestamptz',
              substitutionValues: {'a': value, 't': instant});
          expect(back.single, [true, true], reason: '$instant');
        }
      });
    }

    test('SET TimeZone: mesmo instante, decodificado no fuso da sessão',
        () async {
      // Comportamento existente (mantido): o ParameterStatus do TimeZone
      // atualiza o TimeZoneSettings da conexão.
      final conn = await open('America/Sao_Paulo');
      const sql = "SELECT '2024-06-01 12:00:00+00'::timestamptz";
      final before = (await conn.query(sql)).single.single as DateTime;
      expect(before.timeZoneOffset, const Duration(hours: -3));
      await conn.execute("SET TimeZone = 'Asia/Tokyo'");
      final after = (await conn.query(sql)).single.single as DateTime;
      expect(after.isAtSameMomentAs(before), isTrue);
      expect(after.timeZoneOffset, const Duration(hours: 9));
      // O texto (protocolo simples) segue o fuso da sessão.
      expect(await conn.query(sql, useSimpleQueryProtocol: true), [
        ['2024-06-01 21:00:00+09']
      ]);
      expect(conn.settings['TimeZone'], 'Asia/Tokyo');
    });
  });

  group('encodings do cliente', () {
    test('latin1: texto, parâmetros e nomes de coluna', () async {
      final conn = _conn(encoding: latin1);
      await conn.open();
      addTearDown(conn.close);
      expect(conn.settings['client_encoding'], 'LATIN1');
      const s = 'çãé ÀÿÑ';
      final r = await conn.query(
          'SELECT @s::text AS "ação", @t:text, length(@s::text)',
          substitutionValues: {'s': s, 't': s});
      expect(r.single, [s, s, 7]);
      expect(r.columnDescriptions.first.columnName, 'ação');
      expect(
          await conn.query("SELECT 'ñ'::text AS \"ç\"",
              useSimpleQueryProtocol: true),
          [
            ['ñ']
          ]);
      expect(await conn.execute("SELECT 'ação'"), 1);
    });

    test('ascii: a conexão abre (SQL_ASCII)', () async {
      // Antes o driver enviava client_encoding 'ascii', que o PostgreSQL
      // recusa.
      final conn = _conn(encoding: ascii);
      await conn.open();
      addTearDown(conn.close);
      expect(conn.settings['client_encoding'], 'SQL_ASCII');
      expect(
          await conn.query('SELECT @s::text, @t:text',
              substitutionValues: {'s': 'abc', 't': 'xyz'}),
          [
            ['abc', 'xyz']
          ]);
    });
  });

  group('sem servidor', () {
    Uint8List errorBytes(Map<String, List<int>> fields) {
      final b = BytesBuilder();
      for (final f in fields.entries) {
        b
          ..addByte(f.key.codeUnitAt(0))
          ..add(f.value)
          ..addByte(0);
      }
      b.addByte(0);
      return b.toBytes();
    }

    test('severidade pelo campo V (não traduzido)', () {
      // lc_messages em alemão: S = 'FEHLER'/'PANIK'; antes ficava unknown.
      for (final pair in [
        ['FEHLER', 'ERROR', PostgreSQLSeverity.error],
        ['PANIK', 'PANIC', PostgreSQLSeverity.panic],
        ['ВАЖНО', 'FATAL', PostgreSQLSeverity.fatal],
      ]) {
        final msg = ErrorResponseMessage(
            errorBytes({
              'S': utf8.encode(pair[0] as String),
              'V': utf8.encode(pair[1] as String),
              'C': utf8.encode('XX000'),
              'M': utf8.encode('m'),
            }),
            utf8);
        expect(PostgreSQLException.fromFields(msg.fields).severity, pair[2]);
      }
      // Sem V (servidores antigos), usa o S.
      final old = ErrorResponseMessage(
          errorBytes({'S': utf8.encode('FATAL'), 'C': utf8.encode('57P01')}),
          utf8);
      expect(PostgreSQLException.fromFields(old.fields).severity,
          PostgreSQLSeverity.fatal);
    });

    test('erro em bytes que o encoding da conexão não decodifica', () {
      // Antes lançava FormatException dentro do leitor de mensagens (sem
      // tratamento) e o erro do servidor se perdia.
      final msg = ErrorResponseMessage(
          errorBytes({
            'S': utf8.encode('FATAL'),
            'C': utf8.encode('22023'),
            'M': utf8.encode('valor inválido para o parâmetro'),
          }),
          ascii);
      final e = PostgreSQLException.fromFields(msg.fields);
      expect(e.code, '22023');
      expect(e.message, 'valor inválido para o parâmetro');
    });
  });
}
