// Erros e recuperação: erros do servidor antes e depois das linhas, timeout,
// cancelamento, conexão derrubada pelo servidor (ociosa, ocupada, dentro de
// transação), close() com trabalho em andamento, falha ao ler uma mensagem,
// LISTEN/NOTIFY com texto fora do ASCII e COPY. Quem está na fila precisa
// falhar (ou terminar), nunca ficar esperando.

import 'dart:async';
import 'dart:convert';

import 'package:postgres_fork/postgres.dart';
import 'package:postgres_fork/postgres_v3_experimental.dart';
import 'package:test/test.dart';

import 'docker.dart';

PostgreSQLConnection _conn({int queryTimeout = 20, Encoding encoding = utf8}) =>
    PostgreSQLConnection('localhost', 5432, 'dart_test',
        username: 'dart',
        password: 'dart',
        timeoutInSeconds: 5,
        queryTimeoutInSeconds: queryTimeout,
        encoding: encoding);

Future<PostgreSQLConnection> _open({int queryTimeout = 20}) async {
  final c = _conn(queryTimeout: queryTimeout);
  await c.open();
  addTearDown(c.close);
  return c;
}

final _endpoint = PgEndpoint(
    host: 'localhost',
    database: 'dart_test',
    username: 'dart',
    password: 'dart');
final _settings = PgSessionSettings(onBadSslCertificate: (_) => true);

Future<PgConnection> _openV3() async {
  final v = await PgConnection.open(_endpoint, sessionSettings: _settings);
  addTearDown(v.close);
  return v;
}

/// O resultado de [f] (valor ou erro), sem erros sem tratamento.
Future<Object?> _settle(Future<Object?> f) =>
    f.then<Object?>((v) => v, onError: (Object e) => e);

Matcher _sqlState(String code) =>
    isA<PostgreSQLException>().having((e) => e.code, 'code', code);

/// Termina o backend [pid] a partir de outra conexão.
Future<void> _terminate(int pid) async {
  final admin = _conn();
  await admin.open();
  try {
    await admin.query('SELECT pg_terminate_backend(@p:int4)',
        substitutionValues: {'p': pid});
  } finally {
    await admin.close();
  }
}

Future<int> _pidV3(PgSession s) async =>
    (await s.execute('SELECT pg_backend_pid()')).single.single as int;

void main() {
  usePostgresDocker();

  group('erros do servidor antes e depois das linhas', () {
    const failures = {
      'antes das linhas': 'SELECT 1/0',
      'depois de algumas linhas': 'SELECT 1/(3-i) FROM generate_series(1,5) i',
      'na conversão de um valor': "SELECT 'x'::int",
      'objeto inexistente': 'SELECT * FROM cov_recovery_nope',
    };

    for (final f in failures.entries) {
      test('${f.key}: cada API e o próximo comando', () async {
        final c = await _open();
        Future<void> next() async {
          expect(await c.query('SELECT 41 AS n'), [
            [41]
          ]);
          expect(await c.execute('SELECT 1'), 1);
        }

        for (var round = 0; round < 2; round++) {
          await expectLater(
              c.query(f.value), throwsA(isA<PostgreSQLException>()));
          await next();
          await expectLater(c.query(f.value, allowReuse: false),
              throwsA(isA<PostgreSQLException>()));
          await next();
          await expectLater(c.query(f.value, useSimpleQueryProtocol: true),
              throwsA(isA<PostgreSQLException>()));
          await next();
          await expectLater(
              c.execute(f.value), throwsA(isA<PostgreSQLException>()));
          await next();
          await expectLater(c.execute('SELECT 1; ${f.value}; SELECT 2'),
              throwsA(isA<PostgreSQLException>()));
          await next();
          await expectLater(c.transaction((ctx) => ctx.query(f.value)),
              throwsA(isA<PostgreSQLException>()));
          await next();
          await expectLater(c.queryStream(f.value).toList(),
              throwsA(isA<PostgreSQLException>()));
          await next();
        }

        final v = await _openV3();
        for (var round = 0; round < 2; round++) {
          await expectLater(
              v.execute(f.value), throwsA(isA<PostgreSQLException>()));
          expect(await v.execute('SELECT 42'), [
            [42]
          ]);
          await expectLater(v.runTx((s) => s.execute(f.value)),
              throwsA(isA<PostgreSQLException>()));
          expect(await v.execute('SELECT 43'), [
            [43]
          ]);
        }
      });
    }
  });

  group('timeout e cancelamento', () {
    test('timeout fora e dentro de transação; quem espera continua', () async {
      final c = await _open(queryTimeout: 10);
      await expectLater(c.query('SELECT pg_sleep(1.5)', timeoutInSeconds: 1),
          throwsA(isA<TimeoutException>()));
      final queued = c.query('SELECT 2');
      expect(await queued, [
        [2]
      ]);

      final outside = c.query('SELECT txid_current_if_assigned() IS NULL');
      final tx = c.transaction((ctx) async {
        await ctx.query('CREATE TEMP TABLE cov_recovery_t (a int)');
        await ctx.query('SELECT pg_sleep(1.5)', timeoutInSeconds: 1);
      });
      await expectLater(tx, throwsA(isA<TimeoutException>()));
      expect(await outside, [
        [true]
      ]);
      // A transação foi desfeita.
      await expectLater(c.query('SELECT * FROM cov_recovery_t'),
          throwsA(_sqlState(PgErrorCode.undefinedTable)));
      expect(await c.query('SELECT 3'), [
        [3]
      ]);
    });

    test('cancelQuery: a consulta falha com 57014 e a fila segue', () async {
      final c = await _open();
      final busy = _settle(c.query('SELECT pg_sleep(10)'));
      final next = c.query('SELECT 5');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await c.cancelQuery();
      expect(await busy, _sqlState(PgErrorCode.queryCanceled));
      expect(await next, [
        [5]
      ]);
      // Cancelada dentro de uma transação: desfaz a transação.
      final tx = _settle(c.transaction((ctx) async {
        await ctx.query('SELECT pg_sleep(10)');
      }));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await c.cancelQuery();
      expect(await tx, _sqlState(PgErrorCode.queryCanceled));
      expect(await c.query('SELECT txid_current_if_assigned() IS NULL'), [
        [true]
      ]);
    });
  });

  group('conexão derrubada pelo servidor (pg_terminate_backend)', () {
    test('ociosa: a próxima chamada falha na hora', () async {
      final c = await _open();
      await _terminate(c.processID);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(c.isClosed, isTrue);
      await expectLater(
          c.query('SELECT 1'), throwsA(isA<PostgreSQLException>()));
      await expectLater(c.transaction((ctx) => ctx.query('SELECT 1')),
          throwsA(isA<PostgreSQLException>()));
    });

    test('ocupada: a consulta e a fila falham com o erro do servidor',
        () async {
      final c = await _open();
      final sw = Stopwatch()..start();
      final futures = [
        _settle(c.query('SELECT pg_sleep(10)')),
        _settle(c.query('SELECT 2')),
        _settle(c.execute('SELECT 3')),
        _settle(c.query('SELECT 4', useSimpleQueryProtocol: true)),
        _settle(c.transaction((ctx) => ctx.query('SELECT 5'))),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await _terminate(c.processID);
      final results = await Future.wait(futures);
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
      for (final r in results) {
        expect(r, _sqlState(PgErrorCode.adminShutdown));
      }
      expect(c.isClosed, isTrue);
    });

    test(
        'dentro de transação: consulta em execução, fila da transação e '
        'chamadas de fora falham na hora', () async {
      // Regressão: as consultas da transação esperavam o timeout (20 s
      // aqui) em vez de falhar quando o servidor encerrava a conexão.
      final c = await _open();
      final sw = Stopwatch()..start();
      final inner = <Future<Object?>>[];
      final started = Completer<void>();
      final tx = _settle(c.transaction((ctx) async {
        await ctx.query('SELECT 1');
        final busy = ctx.query('SELECT pg_sleep(10)');
        inner
          ..add(_settle(ctx.query('SELECT 2')))
          ..add(_settle(ctx.execute('SELECT 3')));
        started.complete();
        await busy;
      }));
      await started.future;
      final outside = [
        _settle(c.query('SELECT 4')),
        _settle(c.transaction((ctx) => ctx.query('SELECT 5'))),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await _terminate(c.processID);
      expect(await tx, _sqlState(PgErrorCode.adminShutdown));
      expect(
          await Future.wait(inner), everyElement(isA<PostgreSQLException>()));
      for (final r in await Future.wait(outside)) {
        expect(r, _sqlState(PgErrorCode.adminShutdown));
      }
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('ociosa dentro de transação', () async {
      final c = await _open();
      final sw = Stopwatch()..start();
      final outside = Completer<Future<Object?>>();
      final tx = _settle(c.transaction((ctx) async {
        await ctx.query('SELECT 1');
        outside.complete(_settle(c.query('SELECT 2')));
        await _terminate(c.processID);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return ctx.query('SELECT 3');
      }));
      expect(await tx, isA<PostgreSQLException>());
      expect(
          await (await outside.future), _sqlState(PgErrorCode.adminShutdown));
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('API v3: ociosa, ocupada e dentro de runTx', () async {
      final idle = await _openV3();
      await _terminate(await _pidV3(idle));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await expectLater(
          idle.execute('SELECT 1'), throwsA(isA<PostgreSQLException>()));

      final busy = await _openV3();
      final busyPid = await _pidV3(busy);
      final futures = [
        _settle(busy.execute('SELECT pg_sleep(10)')),
        _settle(busy.execute('SELECT 2')),
        _settle(busy.execute(PgSql(r'SELECT $1', types: [PgDataType.integer]),
            parameters: [3])),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final sw = Stopwatch()..start();
      await _terminate(busyPid);
      final results = await Future.wait(futures);
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
      expect(results, everyElement(isA<PostgreSQLException>()));
      expect(results.first, _sqlState(PgErrorCode.adminShutdown));

      final inTx = await _openV3();
      final txPid = await _pidV3(inTx);
      final outside = <Future<Object?>>[];
      final tx = _settle(inTx.runTx((s) async {
        outside.add(_settle(inTx.execute('SELECT 1')));
        await s.execute('SELECT 1');
        await _terminate(txPid);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return s.execute('SELECT 2');
      }));
      expect(await tx, isA<PostgreSQLException>());
      expect(
          await Future.wait(outside), everyElement(isA<PostgreSQLException>()));
    });
  });

  group('close() com trabalho em andamento', () {
    test(
        'API v2: consultas e transações na fila falham sem erro sem '
        'tratamento', () async {
      // Regressão: uma transação na fila quando a conexão fechava gerava um
      // segundo erro sem tratamento (o do proxy da transação).
      final c = _conn();
      await c.open();
      final futures = [
        _settle(c.query('SELECT pg_sleep(1)')),
        _settle(c.query('SELECT 2')),
        _settle(c.transaction((ctx) => ctx.query('SELECT 3'))),
        _settle(c.transaction((ctx) => ctx.query('SELECT 4'))),
        _settle(c.execute('SELECT 5')),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await c.close();
      final results = await Future.wait(futures);
      expect(results, everyElement(isA<PostgreSQLException>()));
      await expectLater(
          c.query('SELECT 1'), throwsA(isA<PostgreSQLException>()));
      await expectLater(c.transaction((ctx) => ctx.query('SELECT 1')),
          throwsA(isA<PostgreSQLException>()));
    });

    test('API v2: close dentro da transação', () async {
      final c = _conn();
      await c.open();
      final queued = <Future<Object?>>[];
      final tx = _settle(c.transaction((ctx) async {
        await ctx.query('SELECT 1');
        queued.add(_settle(ctx.query('SELECT 2')));
        queued.add(_settle(c.query('SELECT 3')));
        await c.close();
        return ctx.query('SELECT 4');
      }));
      expect(await tx, isA<PostgreSQLException>());
      expect(
          await Future.wait(queued), everyElement(isA<PostgreSQLException>()));
    });

    test('API v3: operações chamadas antes do close terminam', () async {
      // Regressão: execute() só entrava na fila depois de um evento; um
      // close() chamado logo em seguida fechava a conexão antes e elas
      // falhavam com "connection was closed".
      final v = await PgConnection.open(_endpoint, sessionSettings: _settings);
      final a = v.execute('SELECT pg_sleep(0.2)');
      final b = v.execute('SELECT 2');
      final closing = v.close();
      final after = _settle(v.execute('SELECT 3'));
      expect((await b).single.single, 2);
      await a;
      await closing;
      expect(await after, isA<PostgreSQLException>());
    });
  });

  group('mensagem que não pode ser lida', () {
    test('fecha a conexão com o erro (antes: exceção sem tratamento)',
        () async {
      // Com SQL_ASCII o servidor não converte o texto: uma notificação com
      // 'ç' não é ASCII e o encoding da conexão não a decodifica.
      final c = _conn(encoding: ascii);
      await c.open();
      addTearDown(c.close);
      await c.listen('cov_recovery_ascii');
      final sw = Stopwatch()..start();
      final notify = _settle(
          c.query("SELECT pg_notify('cov_recovery_ascii', E'\\u00e7')"));
      final queued = _settle(c.query('SELECT 1'));
      final results = await Future.wait([notify, queued]);
      expect(results.last,
          anyOf(isA<FormatException>(), isA<PostgreSQLException>()));
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
      expect(c.isClosed, isTrue);
    });
  });

  group('LISTEN/NOTIFY', () {
    const channel = 'cov_canal_ação';
    final payloads = [
      'olá 漢字 😀',
      String.fromCharCodes([39, 34, 92]),
      '',
      'x' * 7000,
    ];

    test('API v2: canal e conteúdo fora do ASCII, transações', () async {
      final listener = await _open();
      final sender = await _open();
      await listener.listen(channel);
      final received = <String>[];
      final sub = listener.notificationsFor(channel).listen((n) {
        received.add(n.payload);
      });
      addTearDown(sub.cancel);
      for (final p in payloads) {
        await sender.notify(channel, p);
      }
      await sender.execute("NOTIFY \"$channel\", 'pelo NOTIFY'");
      // Desfeita: não é entregue; confirmada: é entregue no COMMIT.
      await expectLater(sender.transaction((ctx) async {
        await ctx.query('SELECT pg_notify(@c, @p)',
            substitutionValues: {'c': channel, 'p': 'desfeita'});
        throw StateError('rollback');
      }), throwsA(isA<StateError>()));
      await sender.transaction((ctx) => ctx.query('SELECT pg_notify(@c, @p)',
          substitutionValues: {'c': channel, 'p': 'confirmada'}));
      // A conexão que escuta continua respondendo às próprias consultas.
      expect(await listener.query('SELECT 1'), [
        [1]
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(received, [...payloads, 'pelo NOTIFY', 'confirmada']);
      await listener.unlisten(channel);
    });

    test('API v3', () async {
      final v = await _openV3();
      final received = <String>[];
      final sub = v.channels[channel].listen(received.add);
      addTearDown(sub.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final sender = await _open();
      for (final p in payloads) {
        await sender.notify(channel, p);
      }
      await v.channels.notify(channel, 'pelo v3');
      expect(await v.execute('SELECT 1'), [
        [1]
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(received, [...payloads, 'pelo v3']);
    });
  });

  group('COPY', () {
    test('COPY seguido de outros comandos, erros e transações', () async {
      final c = await _open();
      await c.execute('CREATE TEMP TABLE cov_recovery_copy (a int, b text)');
      expect(
          await c.copyFrom('COPY cov_recovery_copy FROM STDIN',
              Stream.value(utf8.encode('1\tção\n2\t\\N\n'))),
          2);
      expect(await c.query('SELECT count(*)::int FROM cov_recovery_copy'), [
        [2]
      ]);
      // Linha inválida: nada gravado, conexão ok.
      await expectLater(
          c.copyFrom('COPY cov_recovery_copy FROM STDIN',
              Stream.value(utf8.encode('3\tx\nnão é int\ty\n'))),
          throwsA(_sqlState(PgErrorCode.invalidTextRepresentation)));
      expect(await c.query('SELECT count(*)::int FROM cov_recovery_copy'), [
        [2]
      ]);
      // COPY FROM STDIN por query()/execute() falha sem travar.
      await expectLater(c.query('COPY cov_recovery_copy FROM STDIN'),
          throwsA(isA<PostgreSQLException>()));
      await expectLater(c.execute('COPY cov_recovery_copy FROM STDIN'),
          throwsA(isA<PostgreSQLException>()));
      final lines = <String>[];
      expect(
          await c.copyTo('COPY cov_recovery_copy TO STDOUT',
              (d) => lines.add(utf8.decode(d))),
          2);
      expect(lines, ['1\tção\n', '2\t\\N\n']);
      // Dentro de transação, com chamadas de fora esperando.
      final outside = c.query('SELECT count(*)::int FROM cov_recovery_copy');
      await c.transaction((ctx) async {
        await ctx.copyRows('cov_recovery_copy', [
          'a',
          'b'
        ], [
          [3, 'três'],
          [4, null],
        ]);
      });
      // Enfileirada antes da transação: roda antes dela.
      expect(await outside, [
        [2]
      ]);
      expect(await c.query('SELECT count(*)::int FROM cov_recovery_copy'), [
        [4]
      ]);
      expect(await c.query('SELECT 99'), [
        [99]
      ]);
    });
  });
}
