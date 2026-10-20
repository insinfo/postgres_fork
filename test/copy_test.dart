// COPY FROM STDIN / TO STDOUT na API v2.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:postgres_fork/postgres.dart';
import 'package:test/test.dart';

import 'docker.dart';

Future<PostgreSQLConnection> _open({int queryTimeout = 30}) async {
  final conn = PostgreSQLConnection('localhost', 5432, 'dart_test',
      username: 'dart',
      password: 'dart',
      queryTimeoutInSeconds: queryTimeout,
      timeoutInSeconds: 5);
  await conn.open();
  addTearDown(conn.close);
  return conn;
}

Stream<List<int>> _chunks(String text, int size) async* {
  final bytes = utf8.encode(text);
  for (var i = 0; i < bytes.length; i += size) {
    yield bytes.sublist(i, i + size > bytes.length ? bytes.length : i + size);
  }
}

void main() {
  group('PgCopy (sem banco)', () {
    Future<String> encode(List<List<Object?>> rows, {int chunkSize = 4}) async {
      final chunks =
          await PgCopy.encodeTextRows(rows, chunkSize: chunkSize).toList();
      return utf8.decode(chunks.expand((c) => c).toList());
    }

    test('escape do formato texto', () async {
      expect(
          await encode([
            ['a\tb', 'c\nd', 'e\rf', r'g\h', null, '', r'\N', 'ç']
          ]),
          'a\\tb\tc\\nd\te\\rf\tg\\\\h\t\\N\t\t\\\\N\tç\n');
    });

    test('valores', () {
      expect(PgCopy.encodeTextValue(42), '42');
      expect(PgCopy.encodeTextValue(-1.5), '-1.5');
      expect(PgCopy.encodeTextValue(double.nan), 'NaN');
      expect(PgCopy.encodeTextValue(double.negativeInfinity), '-Infinity');
      expect(PgCopy.encodeTextValue(true), 't');
      expect(PgCopy.encodeTextValue(DateTime.utc(2024, 2, 29, 23, 5, 6, 7, 8)),
          '2024-02-29 23:05:06.007008+00:00');
      expect(PgCopy.encodeTextValue(DateTime.utc(0, 1, 2)),
          '0001-01-02 00:00:00.000000+00:00 BC');
      expect(PgCopy.encodeTextValue(Uint8List.fromList([0, 15, 255])),
          r'\x000fff');
      expect(PgCopy.encodeTextValue({'a': 1}), '{"a":1}');
      expect(
          PgCopy.encodeTextValue([
            1,
            null,
            'x,"y"\\',
            [2, 3]
          ]),
          r'{"1",NULL,"x,\"y\"\\",{"2","3"}}');
      expect(() => PgCopy.encodeTextValue(Object()), throwsArgumentError);
    });

    test('número de colunas', () {
      expect(
          PgCopy.encodeTextRows([
            [1, 2],
            [3]
          ], columnCount: 2)
              .toList(),
          throwsArgumentError);
    });

    test('decodeTextRow', () {
      expect(PgCopy.decodeTextRow(utf8.encode('a\\tb\t\\N\t\tç\\\\\\n\n')),
          ['a\tb', null, '', 'ç\\\n']);
    });
  });

  group('COPY', () {
    usePostgresDocker();

    test('copyRows: muitas linhas e tipos variados (ida e volta)', () async {
      final conn = await _open();
      await conn.execute('CREATE TEMP TABLE t (id int, txt text, flag bool, '
          'f8 float8, ts timestamp, tstz timestamptz, d date, b bytea, '
          'ia int[], ta text[], j jsonb, iv interval, ip inet, n numeric)');
      final base = DateTime.utc(2024, 1, 15, 10, 30, 45, 123, 456);
      List<Object?> row(int i) => [
            i,
            i.isEven ? 'linha $i\t\n\\ "x" ç' : null,
            i % 3 == 0,
            i / 7,
            base.add(Duration(minutes: i)),
            base.add(Duration(seconds: i)),
            base.add(Duration(days: i % 400)),
            Uint8List.fromList([i % 256, 0, 255]),
            [i, null, -i],
            ['a,b', null, 'NULL', '', '{}'],
            {'i': i, 's': 'v"$i'},
            PgInterval(months: i % 13, days: 1, microseconds: i),
            PgInet(InternetAddress('10.0.${i % 256}.1'), 24),
            '$i.5',
          ];
      const count = 50000;
      final inserted = await conn.copyRows(
          't',
          [
            'id', 'txt', 'flag', 'f8', 'ts', 'tstz', 'd', 'b', 'ia', 'ta', //
            'j', 'iv', 'ip', 'n'
          ],
          Iterable.generate(count, row));
      expect(inserted, count);

      final rows = await conn.query(
          'SELECT id, txt, flag, f8, ts, tstz, d, b, ia, ta, j, iv::text, '
          "format('%s', ip), n::text FROM t WHERE id IN (0, 1, 7, 49999) "
          'ORDER BY id');
      expect(rows.length, 4);
      for (final r in rows) {
        final i = r[0] as int;
        final expected = row(i);
        expect(r[1], expected[1]);
        expect(r[2], expected[2]);
        expect(r[3], expected[3]);
        expect(r[4], base.add(Duration(minutes: i)));
        expect((r[5] as DateTime).isAtSameMomentAs(base.add(Duration(seconds: i))),
            isTrue);
        final d = base.add(Duration(days: i % 400));
        expect(r[6], DateTime.utc(d.year, d.month, d.day));
        expect(r[7], expected[7]);
        expect(r[8], [i, null, -i]);
        expect(r[9], ['a,b', null, 'NULL', '', '{}']);
        expect(r[10], {'i': i, 's': 'v"$i'});
        expect(r[13], '$i.5');
      }
      final iv = (await conn.query(
              'SELECT iv = make_interval(months => 7, days => 1) + '
              "make_interval(secs => 0.000007), format('%s', ip) "
              'FROM t WHERE id = 7'))
          .first;
      expect(iv, [true, '10.0.7.1/24']);
      expect(await conn.query('SELECT count(*)::int FROM t'), [
        [count]
      ]);
    });

    test('copyFrom: texto em blocos que cortam linhas e CSV', () async {
      final conn = await _open();
      await conn.execute('CREATE TEMP TABLE t (id int, txt text)');
      final text = StringBuffer();
      for (var i = 0; i < 1000; i++) {
        text.write('$i\tvalor ç $i\n');
      }
      expect(await conn.copyFrom('COPY t FROM STDIN', _chunks('$text', 7)),
          1000);
      expect(
          await conn.copyFrom('COPY t FROM STDIN WITH (FORMAT csv)',
              _chunks('2000,"a,b"\n2001,"x""y"\n2002,\n', 3)),
          3);
      final rows = await conn.query(
          'SELECT id, txt FROM t WHERE id IN (999, 2000, 2001, 2002) '
          'ORDER BY id');
      expect(rows, [
        [999, 'valor ç 999'],
        [2000, 'a,b'],
        [2001, 'x"y'],
        [2002, null],
      ]);
    });

    test('copyFrom com @ no SQL não processa placeholders', () async {
      final conn = await _open();
      await conn.execute('CREATE TEMP TABLE t (a text, b text)');
      expect(
          await conn.copyFrom("COPY t FROM STDIN WITH (FORMAT csv, DELIMITER '@')",
              _chunks('x@y\n', 100)),
          1);
      expect(await conn.query('SELECT a, b FROM t'), [
        ['x', 'y']
      ]);
    });

    test('erro do servidor no meio dos dados: nada gravado e conexão ok',
        () async {
      final conn = await _open();
      await conn.execute('CREATE TEMP TABLE t (id int)');
      final data = StringBuffer();
      for (var i = 0; i < 300000; i++) {
        data.write(i == 10 ? 'abc\n' : '$i\n');
      }
      await expectLater(
          conn.copyFrom('COPY t FROM STDIN', _chunks('$data', 64 * 1024)),
          throwsA(isA<PostgreSQLException>()
              .having((e) => e.code, 'code', '22P02')));
      expect(await conn.query('SELECT count(*)::int FROM t'), [
        [0]
      ]);
    });

    test('erro do servidor com stream lento ainda em andamento', () async {
      final conn = await _open();
      await conn.execute('CREATE TEMP TABLE t (id int)');
      final controller = StreamController<List<int>>();
      controller.add(utf8.encode('1\nabc\n'));
      // O controller nunca é fechado: o COPY tem de terminar pelo erro do
      // servidor mesmo assim.
      final future = conn.copyFrom('COPY t FROM STDIN', controller.stream);
      // Força o envio dos dados.
      await expectLater(
          future.timeout(const Duration(seconds: 10)),
          throwsA(isA<PostgreSQLException>()
              .having((e) => e.code, 'code', '22P02')));
      expect(controller.hasListener, isFalse);
      expect(await conn.query('SELECT 1'), [
        [1]
      ]);
    });

    test('erro no stream de dados aborta o COPY', () async {
      final conn = await _open();
      await conn.execute('CREATE TEMP TABLE t (id int)');
      Stream<List<int>> data() async* {
        yield utf8.encode('1\n2\n');
        throw StateError('falha na origem');
      }

      await expectLater(conn.copyFrom('COPY t FROM STDIN', data()),
          throwsA(isA<StateError>()));
      expect(await conn.query('SELECT count(*)::int FROM t'), [
        [0]
      ]);
    });

    test('copyRows com linha inválida não grava nada', () async {
      final conn = await _open();
      await conn.execute('CREATE TEMP TABLE t (id int, x text)');
      await expectLater(
          conn.copyRows('t', [
            'id',
            'x'
          ], [
            [1, 'a'],
            [2],
          ]),
          throwsArgumentError);
      await expectLater(
          conn.copyRows('t', [
            'id',
            'x'
          ], [
            [1, Object()],
          ]),
          throwsArgumentError);
      expect(await conn.query('SELECT count(*)::int FROM t'), [
        [0]
      ]);
    });

    test('COPY FROM STDIN por query/execute falha sem travar', () async {
      final conn = await _open();
      await conn.execute('CREATE TEMP TABLE t (id int)');
      for (final run in <Future<Object?> Function()>[
        () => conn.execute('COPY t FROM STDIN'),
        () => conn.query('COPY t FROM STDIN'),
        () => conn.query('COPY t FROM STDIN', useSimpleQueryProtocol: true),
      ]) {
        await expectLater(
            run().timeout(const Duration(seconds: 10)),
            throwsA(isA<PostgreSQLException>()
                .having((e) => e.message, 'message', contains('copyFrom'))));
        // A próxima consulta recebe o próprio resultado (sem ReadyForQuery
        // a mais ou a menos).
        expect(await conn.query('SELECT 7'), [
          [7]
        ]);
        expect(await conn.execute('SELECT 1 UNION SELECT 2'), 2);
      }
    });

    test('copyTo e decodeTextRow', () async {
      final conn = await _open();
      await conn.execute('CREATE TEMP TABLE t (id int, txt text)');
      await conn.copyRows('t', [
        'id',
        'txt'
      ], [
        [1, 'a\tb\\c\nd'],
        [2, null],
        [3, 'w começa com w'],
        [4, 'k'],
      ]);
      final lines = <List<String?>>[];
      final count = await conn.copyTo(
          'COPY (SELECT * FROM t ORDER BY id) TO STDOUT',
          (data) => lines.add(PgCopy.decodeTextRow(data)));
      expect(count, 4);
      expect(lines, [
        ['1', 'a\tb\\c\nd'],
        ['2', null],
        ['3', 'w começa com w'],
        ['4', 'k'],
      ]);

      final csv = BytesBuilder();
      expect(
          await conn.copyTo(
              'COPY (SELECT id FROM t WHERE id > @min ORDER BY id) '
              'TO STDOUT WITH (FORMAT csv)',
              csv.add,
              substitutionValues: {'min': 2}),
          2);
      expect(utf8.decode(csv.takeBytes()), '3\n4\n');
    });

    test('copyTo: exceção no handler e COPY TO por query comum', () async {
      final conn = await _open();
      await conn.execute(
          "CREATE TEMP TABLE t AS SELECT 'w' || g AS v FROM generate_series(1, 100) g");
      var calls = 0;
      await expectLater(
          conn.copyTo('COPY t TO STDOUT', (_) {
            calls++;
            throw FormatException('handler');
          }),
          throwsA(isA<FormatException>()));
      expect(calls, 1);
      expect(await conn.query('SELECT count(*)::int FROM t'), [
        [100]
      ]);
      // Dados que começam com "w"/"k" não são confundidos com mensagens de
      // replicação.
      expect(await conn.execute('COPY t TO STDOUT'), 100);
      expect(await conn.query('COPY t TO STDOUT'), isEmpty);
      expect(await conn.query('SELECT 5'), [
        [5]
      ]);
    });

    test('COPY dentro de transação: commit e rollback', () async {
      final conn = await _open();
      await conn.execute('CREATE TEMP TABLE t (id int)');
      await conn.transaction((ctx) async {
        expect(
            await ctx.copyRows('t', ['id'], [
              [1],
              [2]
            ]),
            2);
        expect(await ctx.copyFrom('COPY t FROM STDIN', _chunks('3\n', 10)), 1);
        final out = <String>[];
        await ctx.copyTo('COPY t TO STDOUT', (d) => out.add(utf8.decode(d)));
        expect(out, ['1\n', '2\n', '3\n']);
      });
      final rollback = await conn.transaction((ctx) async {
        await ctx.copyRows('t', ['id'], [
          [4]
        ]);
        ctx.cancelTransaction(reason: 'teste');
      });
      expect(rollback, isA<PostgreSQLRollback>());
      // Erro no COPY falha a transação inteira.
      await expectLater(
          conn.transaction((ctx) async {
            await ctx.copyRows('t', ['id'], [
              [5]
            ]);
            await ctx.copyFrom('COPY t FROM STDIN', _chunks('x\n', 10));
          }),
          throwsA(isA<PostgreSQLException>()));
      expect(await conn.query('SELECT array_agg(id ORDER BY id) FROM t'), [
        [
          [1, 2, 3]
        ]
      ]);
    });

    test('consultas na fila esperam o COPY', () async {
      final conn = await _open();
      await conn.execute('CREATE TEMP TABLE t (id int)');
      final copy = conn.copyRows(
          't', ['id'], Iterable.generate(100000, (i) => [i]));
      final count = conn.query('SELECT count(*)::int FROM t');
      expect(await copy, 100000);
      expect(await count, [
        [100000]
      ]);
    });

    test('timeout aborta o COPY e a conexão continua utilizável', () async {
      final conn = await _open(queryTimeout: 2);
      await conn.execute('CREATE TEMP TABLE t (id int)');
      final controller = StreamController<List<int>>();
      controller.add(utf8.encode('1\n'));
      final sw = Stopwatch()..start();
      await expectLater(conn.copyFrom('COPY t FROM STDIN', controller.stream),
          throwsA(isA<TimeoutException>()));
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
      expect(await conn.query('SELECT count(*)::int FROM t'), [
        [0]
      ]);
      await controller.close();
    });

    test('close durante o COPY', () async {
      final conn = await _open();
      await conn.execute('CREATE TEMP TABLE t (id int)');
      final controller = StreamController<List<int>>();
      controller.add(utf8.encode('1\n'));
      final copy = conn.copyFrom('COPY t FROM STDIN', controller.stream);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await conn.close();
      await expectLater(copy, throwsA(isA<PostgreSQLException>()));
      await controller.close();
    });

    test('COPY grande com SSL (flush no SecureSocket)', () async {
      final conn = PostgreSQLConnection('localhost', 5432, 'dart_test',
          username: 'dart', password: 'dart', sslMode: PgSslMode.require);
      await conn.open();
      addTearDown(conn.close);
      await conn.execute('CREATE TEMP TABLE t (id int, txt text)');
      final rows = Iterable.generate(200000, (i) => [i, 'texto $i' * 3]);
      expect(await conn.copyRows('t', ['id', 'txt'], rows), 200000);
      var bytes = 0;
      expect(await conn.copyTo('COPY t TO STDOUT', (d) => bytes += d.length),
          200000);
      expect(bytes, greaterThan(4 << 20));
      expect(await conn.query('SELECT sum(id)::bigint FROM t'), [
        [199999 * 200000 ~/ 2]
      ]);
    });

    test('extensão em PostgreSQLExecutionContext', () async {
      final conn = await _open();
      await conn.execute('CREATE TEMP TABLE t (id int)');
      final PostgreSQLExecutionContext ctx = conn;
      expect(
          await ctx.copyRows('t', ['id'], [
            [1]
          ]),
          1);
    });
  });
}
