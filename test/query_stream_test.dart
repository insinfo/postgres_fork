// queryStream: cursores no servidor com controle de fluxo.

import 'dart:async';

import 'package:postgres_fork/postgres.dart';
import 'package:test/test.dart';

import 'docker.dart';

Future<PostgreSQLConnection> _open() async {
  final conn = PostgreSQLConnection('localhost', 5432, 'dart_test',
      username: 'dart', password: 'dart');
  await conn.open();
  addTearDown(conn.close);
  return conn;
}

/// Cursores abertos (sem o portal sem nome da própria consulta).
Future<int> _openCursors(PostgreSQLExecutionContext ctx) async => (await ctx
        .query("SELECT count(*)::int FROM pg_cursors WHERE name <> ''"))
    .first
    .first as int;

void main() {
  usePostgresDocker();

  test('muitas linhas, em ordem e com os tipos decodificados', () async {
    final conn = await _open();
    var expected = 1;
    await for (final row in conn.queryStream(
        "SELECT g, 'linha ' || g AS t, g::numeric / 4 AS q "
        'FROM generate_series(1, 100000) g',
        fetchSize: 1000)) {
      expect(row[0], expected);
      if (expected == 99999) {
        expect(row[1], 'linha 99999');
        expect(row[2], '24999.750000000000');
        expect(row.toColumnMap().keys, ['g', 't', 'q']);
      }
      expected++;
    }
    expect(expected, 100001);
    expect(await _openCursors(conn), 0);
    expect(await conn.query('SELECT 1'), [
      [1]
    ]);
  });

  test('resultado vazio e lote exato', () async {
    final conn = await _open();
    expect(
        await conn
            .queryStream('SELECT 1 WHERE false', fetchSize: 10)
            .toList(),
        isEmpty);
    final rows = await conn
        .queryStream('SELECT g FROM generate_series(1, 20) g', fetchSize: 10)
        .toList();
    expect(rows.map((r) => r[0]), List.generate(20, (i) => i + 1));
  });

  test('parâmetros com @ e com ?', () async {
    final conn = await _open();
    final a = await conn
        .queryStream('SELECT g FROM generate_series(1, @n:int4) g WHERE g > @m',
            substitutionValues: {'n': 10, 'm': 7}, fetchSize: 2)
        .map((r) => r[0])
        .toList();
    expect(a, [8, 9, 10]);
    final b = await conn
        .queryStream('SELECT g FROM generate_series(1, ?::int4) g WHERE g > ?',
            substitutionValues: [5, 3],
            placeholderIdentifier: PlaceholderIdentifier.onlyQuestionMark)
        .map((r) => r[0])
        .toList();
    expect(b, [4, 5]);
  });

  test('controle de fluxo: o servidor só produz o que é pedido', () async {
    final conn = await _open();
    final monitor = await _open();
    await monitor.execute('DROP SEQUENCE IF EXISTS stream_seq');
    await monitor.execute('CREATE SEQUENCE stream_seq');
    addTearDown(() => monitor.execute('DROP SEQUENCE IF EXISTS stream_seq'));

    Future<int> produced() async => (await monitor
            .query('SELECT last_value::int FROM stream_seq'))
        .first
        .first as int;

    final received = <int>[];
    final firstRows = Completer<void>();
    final subscription = conn
        .queryStream(
            "SELECT nextval('stream_seq')::int FROM generate_series(1, 1000000)",
            fetchSize: 100)
        .listen((row) {
      received.add(row[0] as int);
      if (received.length == 5 && !firstRows.isCompleted) firstRows.complete();
    });
    await firstRows.future;
    subscription.pause();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    // No máximo uns dois lotes além do que foi consumido.
    expect(await produced(), lessThanOrEqualTo(300));
    subscription.resume();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await subscription.cancel();
    final atCancel = await produced();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(await produced(), atCancel);
    expect(atCancel, lessThan(1000000));
    // Sem cursor aberto e com a transação encerrada.
    expect(await _openCursors(conn), 0);
    expect(await conn.query('SELECT 1'), [
      [1]
    ]);
  });

  test('cancelar com break fecha o cursor', () async {
    final conn = await _open();
    var count = 0;
    await for (final _ in conn.queryStream(
        'SELECT g FROM generate_series(1, 100000) g',
        fetchSize: 50)) {
      if (++count == 120) break;
    }
    expect(count, 120);
    expect(await _openCursors(conn), 0);
    // Transação do cursor encerrada: a conexão está fora de transação.
    await conn.execute('BEGIN');
    await conn.execute('COMMIT');
  });

  test('erro de SQL e erro no meio do stream', () async {
    final conn = await _open();
    await expectLater(conn.queryStream('SELEC 1').toList(),
        throwsA(isA<PostgreSQLException>()));
    final rows = <Object?>[];
    Object? error;
    try {
      await for (final row in conn.queryStream(
          'SELECT 1 / (2500 - g) FROM generate_series(1, 5000) g',
          fetchSize: 1000)) {
        rows.add(row[0]);
      }
    } catch (e) {
      error = e;
    }
    expect(rows.length, 2000);
    expect(error, isA<PostgreSQLException>()
        .having((e) => e.code, 'code', '22012'));
    expect(await conn.query('SELECT 2'), [
      [2]
    ]);
  });

  test('consultas da conexão esperam o stream', () async {
    final conn = await _open();
    final stream = conn.queryStream(
        'SELECT g FROM generate_series(1, 5000) g',
        fetchSize: 100);
    final list = stream.toList();
    final other = conn.query("SELECT current_setting('transaction_isolation')");
    expect((await list).length, 5000);
    expect((await other).first.first, isA<String>());
  });

  group('dentro de transaction', () {
    test('lê dados da própria transação e confirma', () async {
      final conn = await _open();
      await conn.execute('CREATE TEMP TABLE s (id int)');
      await conn.transaction((ctx) async {
        await ctx.execute('INSERT INTO s SELECT generate_series(1, 2500)');
        var sum = 0;
        await for (final row
            in ctx.queryStream('SELECT id FROM s', fetchSize: 1000)) {
          sum += row[0] as int;
        }
        expect(sum, 2500 * 2501 ~/ 2);
        expect(await _openCursors(ctx), 0);
      });
      expect(await conn.query('SELECT count(*)::int FROM s'), [
        [2500]
      ]);
    });

    test('dois streams intercalados na mesma transação', () async {
      final conn = await _open();
      await conn.transaction((ctx) async {
        final a = StreamIterator(ctx.queryStream(
            'SELECT g FROM generate_series(1, 30) g',
            fetchSize: 7));
        final b = StreamIterator(ctx.queryStream(
            'SELECT -g FROM generate_series(1, 30) g',
            fetchSize: 4));
        for (var i = 1; i <= 30; i++) {
          expect(await a.moveNext(), isTrue);
          expect(await b.moveNext(), isTrue);
          expect(a.current[0], i);
          expect(b.current[0], -i);
        }
        expect(await a.moveNext(), isFalse);
        expect(await b.moveNext(), isFalse);
      });
    });

    test('stream não consumido recebe erro e a transação confirma', () async {
      final conn = await _open();
      await conn.execute('CREATE TEMP TABLE s (id int)');
      late StreamSubscription<PostgreSQLResultRow> subscription;
      final error = Completer<Object>();
      final result = await conn.transaction((ctx) async {
        await ctx.execute('INSERT INTO s VALUES (1)');
        final firstRow = Completer<void>();
        subscription = ctx
            .queryStream('SELECT g FROM generate_series(1, 100000) g',
                fetchSize: 10)
            .listen((_) {
          if (!firstRow.isCompleted) firstRow.complete();
        }, onError: error.complete);
        await firstRow.future;
        subscription.pause();
        return 'fim';
      });
      expect(result, 'fim');
      // Eventos de uma inscrição pausada ficam no buffer até o resume.
      subscription.resume();
      expect(await error.future, isA<StateError>());
      expect(await conn.query('SELECT count(*)::int FROM s'), [
        [1]
      ]);
      expect(await _openCursors(conn), 0);
      await subscription.cancel();
    });

    test('erro no stream desfaz a transação; com savepoint, só o savepoint',
        () async {
      final conn = await _open();
      await conn.execute('CREATE TEMP TABLE s (id int)');
      await expectLater(
          conn.transaction((ctx) async {
            await ctx.execute('INSERT INTO s VALUES (1)');
            await ctx.queryStream('SELECT 1/0').toList();
          }),
          throwsA(isA<PostgreSQLException>()));
      expect(await conn.query('SELECT count(*)::int FROM s'), [
        [0]
      ]);
      await conn.transaction((ctx) async {
        await ctx.execute('INSERT INTO s VALUES (2)');
        await expectLater(
            ctx.savepoint((sp) => sp.queryStream('SELECT 1/0').toList()),
            throwsA(isA<PostgreSQLException>()));
        await ctx.execute('INSERT INTO s VALUES (3)');
      });
      expect(await conn.query('SELECT array_agg(id ORDER BY id) FROM s'), [
        [
          [2, 3]
        ]
      ]);
    });

    test('stream ouvido depois do fim da transação', () async {
      final conn = await _open();
      late Stream<PostgreSQLResultRow> stream;
      await conn.transaction((ctx) async {
        stream = ctx.queryStream('SELECT 1');
      });
      await expectLater(stream.toList(), throwsStateError);
    });
  });

  test('close da conexão durante o stream', () async {
    final conn = PostgreSQLConnection('localhost', 5432, 'dart_test',
        username: 'dart', password: 'dart');
    await conn.open();
    final done = Completer<Object?>();
    final subscription = conn
        .queryStream('SELECT g FROM generate_series(1, 1000000) g',
            fetchSize: 10)
        .listen((_) {}, onError: done.complete, onDone: () {
      if (!done.isCompleted) done.complete(null);
    });
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await conn.close();
    final result = await done.future.timeout(const Duration(seconds: 10));
    expect(result, isA<PostgreSQLException>());
    await subscription.cancel();
  });

  test('close durante uma transação falha as consultas na hora', () async {
    final conn = PostgreSQLConnection('localhost', 5432, 'dart_test',
        username: 'dart', password: 'dart');
    await conn.open();
    final sw = Stopwatch()..start();
    final tx = conn.transaction((ctx) async {
      await ctx.query('SELECT 1');
      final slow = ctx.query('SELECT pg_sleep(20)');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      unawaited(conn.close());
      await slow;
    });
    await expectLater(tx, throwsA(isA<PostgreSQLException>()));
    expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
  });

  test('fetchSize inválido', () async {
    final conn = await _open();
    expect(() => conn.queryStream('SELECT 1', fetchSize: 0),
        throwsArgumentError);
  });
}
