// PostgreSQLPool (API v2) e PgPool (API v3) contra o servidor.

import 'dart:async';

import 'package:postgres_fork/postgres.dart';
import 'package:postgres_fork/postgres_v3_experimental.dart';
import 'package:test/test.dart';

import 'docker.dart';

PostgreSQLConnection _factory() => PostgreSQLConnection(
    'localhost', 5432, 'dart_test',
    username: 'dart', password: 'dart', applicationName: 'pool_test');

PostgreSQLPool _pool([PostgreSQLPoolSettings settings =
        const PostgreSQLPoolSettings(maxConnectionCount: 3)]) {
  final pool = PostgreSQLPool(_factory, settings: settings);
  addTearDown(() => pool.close(force: true));
  return pool;
}

Future<int> _pid(PostgreSQLExecutionContext c) async =>
    (await c.query('SELECT pg_backend_pid()')).first.first as int;

class _Retryable implements Exception {}

void main() {
  usePostgresDocker();

  group('PostgreSQLPool', () {
    test('concorrência limitada e conexões reutilizadas', () async {
      final pool = _pool();
      final pids = <int>{};
      await Future.wait(List.generate(30, (i) async {
        await pool.run((c) async {
          pids.add(await _pid(c));
          await c.query('SELECT pg_sleep(0.01)');
        });
      }));
      expect(pids.length, lessThanOrEqualTo(3));
      expect(pool.status.connectionCount, pids.length);
      expect(pool.status.idleCount, pids.length);
      // Métodos de PostgreSQLExecutionContext.
      expect(await pool.query('SELECT 1'), [
        [1]
      ]);
      expect(await pool.execute('SELECT 1 UNION SELECT 2'), 2);
      expect(await pool.queryAsMap('SELECT 1 AS a'), [
        {'a': 1}
      ]);
    });

    test('onOpen e erro de SQL não descartam a conexão', () async {
      var opened = 0;
      final pool = _pool(PostgreSQLPoolSettings(
          maxConnectionCount: 1,
          onOpen: (c) async {
            opened++;
            await c.execute("SET search_path TO 'pg_catalog'");
          }));
      final pid = await pool.run(_pid);
      await expectLater(
          pool.execute('SELECT * FROM tabela_que_nao_existe'),
          throwsA(isA<PostgreSQLException>()));
      expect(await pool.run(_pid), pid);
      expect(
          (await pool.query('SHOW search_path')).first.first, 'pg_catalog');
      expect(opened, 1);
    });

    test('BEGIN sem COMMIT e timeout descartam a conexão', () async {
      final pool = _pool(const PostgreSQLPoolSettings(maxConnectionCount: 1));
      final first = await pool.run((c) async {
        await c.execute('BEGIN');
        return _pid(c);
      });
      final second = await pool.run(_pid);
      expect(second, isNot(first));
      // A conexão nova está fora de transação: um BEGIN não gera aviso e
      // um COMMIT vazio funciona.
      await pool.run((c) async {
        await c.execute('BEGIN');
        await c.execute('COMMIT');
      });
      await expectLater(
          pool.query('SELECT pg_sleep(3)', timeoutInSeconds: 1),
          throwsA(isA<TimeoutException>()));
      expect(await pool.run(_pid), isNot(second));
    });

    test('runTx: commit, rollback por erro e cancelTransaction', () async {
      final pool = _pool();
      await pool.execute('DROP TABLE IF EXISTS pool_tx');
      await pool.execute('CREATE TABLE pool_tx (id int)');
      try {
        expect(
            await pool.runTx((ctx) async {
              await ctx.execute('INSERT INTO pool_tx VALUES (1)');
              return 'ok';
            }),
            'ok');
        await expectLater(
            pool.runTx((ctx) async {
              await ctx.execute('INSERT INTO pool_tx VALUES (2)');
              await ctx.execute('SELECT 1/0');
            }),
            throwsA(isA<PostgreSQLException>()));
        await expectLater(
            pool.runTx<int>((ctx) async {
              await ctx.execute('INSERT INTO pool_tx VALUES (3)');
              ctx.cancelTransaction(reason: 'desisti');
              return 1;
            }),
            throwsA(isA<PostgreSQLRollback>()
                .having((r) => r.reason, 'reason', 'desisti')));
        final dyn = await pool.runTx<Object?>((ctx) async {
          ctx.cancelTransaction(reason: 'r');
          return null;
        });
        expect(dyn, isA<PostgreSQLRollback>());
        expect(await pool.query('SELECT array_agg(id) FROM pool_tx'), [
          [
            [1]
          ]
        ]);
      } finally {
        await pool.execute('DROP TABLE IF EXISTS pool_tx');
      }
    });

    test('retryOptions repete com outra tentativa', () async {
      final pool = _pool();
      var attempts = 0;
      final result = await pool.runTx((ctx) async {
        attempts++;
        if (attempts < 3) throw _Retryable();
        return attempts;
      },
          retryOptions: PgRetryOptions(
              delay: const Duration(milliseconds: 1),
              retryIf: (e) => e is _Retryable));
      expect(result, 3);
      attempts = 0;
      await expectLater(
          pool.run((ctx) async {
            attempts++;
            await ctx.execute('SELECT 1/0');
          }, retryOptions: const PgRetryOptions()),
          throwsA(isA<PostgreSQLException>()));
      expect(attempts, 1);
    });

    test('conexão derrubada pelo servidor é substituída', () async {
      final pool = _pool(const PostgreSQLPoolSettings(
          maxConnectionCount: 1, idleTestThreshold: Duration.zero));
      final pid = await pool.run(_pid);
      final admin = _factory();
      await admin.open();
      addTearDown(admin.close);
      await admin.query('SELECT pg_terminate_backend(@p:int4)',
          substitutionValues: {'p': pid});
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final next = await pool.run(_pid);
      expect(next, isNot(pid));
    });

    test('queryStream ocupa a conexão até o fim; COPY pelo pool', () async {
      final pool = _pool(const PostgreSQLPoolSettings(maxConnectionCount: 1));
      var count = 0;
      final other = Completer<int>();
      await for (final _ in pool.queryStream(
          'SELECT g FROM generate_series(1, 3000) g',
          fetchSize: 500)) {
        if (count++ == 0) {
          // Espera a conexão (única) ser devolvida.
          unawaited(pool.query('SELECT 7').then((r) => other.complete(
              r.first.first as int)));
        }
      }
      expect(count, 3000);
      expect(await other.future, 7);
      // Cancelar devolve a conexão.
      await for (final _ in pool.queryStream(
          'SELECT g FROM generate_series(1, 100000) g',
          fetchSize: 100)) {
        break;
      }
      expect(pool.status.idleCount, 1);

      await pool.execute('DROP TABLE IF EXISTS pool_copy');
      await pool.execute('CREATE TABLE pool_copy (id int)');
      try {
        final PostgreSQLExecutionContext ctx = pool;
        expect(
            await ctx.copyRows('pool_copy', [
              'id'
            ], [
              [1],
              [2]
            ]),
            2);
        expect(await ctx.queryStream('SELECT id FROM pool_copy').length, 2);
      } finally {
        await pool.execute('DROP TABLE IF EXISTS pool_copy');
      }
    });

    test('acquireTimeout e close', () async {
      final pool = PostgreSQLPool(_factory,
          settings: const PostgreSQLPoolSettings(
              maxConnectionCount: 1,
              acquireTimeout: Duration(milliseconds: 200)));
      final busy = pool.query('SELECT pg_sleep(1)');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await expectLater(
          pool.query('SELECT 1'), throwsA(isA<TimeoutException>()));
      await busy;
      await pool.close();
      expect(pool.isClosed, isTrue);
      expect(pool.status.connectionCount, 0);
      await expectLater(pool.query('SELECT 1'), throwsStateError);
    });
  });

  group('PgPool (v3)', () {
    Future<PgPool> open([int max = 2]) async {
      final pool = await PgPool.open([
        PgEndpoint(
            host: 'localhost',
            database: 'dart_test',
            username: 'dart',
            password: 'dart')
      ],
          sessionSettings:
              PgSessionSettings(onBadSslCertificate: (_) => true),
          poolSettings: PgPoolSettings(maxConnectionCount: max));
      addTearDown(pool.close);
      return pool;
    }

    test('execute, run, runTx e concorrência', () async {
      final pool = await open();
      expect(await pool.execute('SELECT 1'), [
        [1]
      ]);
      final pids = <int>{};
      await Future.wait(List.generate(10, (_) async {
        await pool.run((s) async {
          final r = await s.execute('SELECT pg_backend_pid()');
          pids.add(r.first.first as int);
        });
      }));
      expect(pids.length, lessThanOrEqualTo(2));
      final value = await pool.runTx((s) async {
        final r = await s.execute('SELECT txid_current_if_assigned() IS NULL');
        return r.first.first;
      });
      expect(value, true);
      await expectLater(
          pool.runTx((s) => s.execute('SELECT 1/0')),
          throwsA(isA<PostgreSQLException>()));
      expect(await pool.execute('SELECT 2'), [
        [2]
      ]);
    });

    test('conexão v3 derrubada durante uma consulta não trava', () async {
      final conn = await PgConnection.open(
          PgEndpoint(
              host: 'localhost',
              database: 'dart_test',
              username: 'dart',
              password: 'dart'),
          sessionSettings: PgSessionSettings(onBadSslCertificate: (_) => true));
      addTearDown(conn.close);
      final pid =
          (await conn.execute('SELECT pg_backend_pid()')).first.first as int;
      final sw = Stopwatch()..start();
      final running = conn.execute('SELECT pg_sleep(20)');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final admin = _factory();
      await admin.open();
      addTearDown(admin.close);
      await admin.query('SELECT pg_terminate_backend(@p:int4)',
          substitutionValues: {'p': pid});
      await expectLater(running, throwsA(isA<PostgreSQLException>()));
      await expectLater(
          conn.execute('SELECT 1'), throwsA(isA<PostgreSQLException>()));
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('withConnection, prepare e conexão derrubada', () async {
      final pool = await open(1);
      final pid = await pool.withConnection((c) async =>
          (await c.execute('SELECT pg_backend_pid()')).first.first as int);
      await expectLater(pool.prepare('SELECT 1'), throwsUnsupportedError);
      final admin = _factory();
      await admin.open();
      addTearDown(admin.close);
      await admin.query('SELECT pg_terminate_backend(@p:int4)',
          substitutionValues: {'p': pid});
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final next = await pool.withConnection((c) async =>
          (await c.execute('SELECT pg_backend_pid()')).first.first as int);
      expect(next, isNot(pid));
    });
  });
}
