// Savepoints dentro de PostgreSQLConnection.transaction.

import 'package:postgres_fork/postgres.dart';
import 'package:test/test.dart';

import 'docker.dart';

void main() {
  usePostgresDocker();

  late PostgreSQLConnection conn;

  setUp(() async {
    conn = PostgreSQLConnection('localhost', 5432, 'dart_test',
        username: 'dart', password: 'dart');
    await conn.open();
    await conn.execute(
        'CREATE TEMP TABLE t (id int CONSTRAINT t_pk PRIMARY KEY, v text)');
  });

  tearDown(() => conn.close());

  Future<List<int>> ids() async {
    final rows = await conn.query('SELECT id FROM t ORDER BY id');
    return rows.map((r) => r.first as int).toList();
  }

  test('erro dentro do savepoint desfaz só o savepoint', () async {
    final result = await conn.transaction((ctx) async {
      await ctx.execute('INSERT INTO t VALUES (1)');
      await expectLater(
          ctx.savepoint((sp) async {
            await sp.execute('INSERT INTO t VALUES (2)');
            await sp.execute('INSERT INTO t VALUES (1)'); // duplicada
          }),
          throwsA(isA<PostgreSQLException>()
              .having((e) => e.code, 'code', PgErrorCode.uniqueViolation)));
      await ctx.execute('INSERT INTO t VALUES (3)');
      return 'ok';
    });
    expect(result, 'ok');
    expect(await ids(), [1, 3]);
  });

  test('savepoint sem erro devolve o valor e mantém as alterações',
      () async {
    await conn.transaction((ctx) async {
      final n = await ctx.savepoint((sp) async {
        await sp.execute('INSERT INTO t VALUES (1), (2)');
        return 2;
      });
      expect(n, 2);
      final rows = await ctx.query('SELECT count(*)::int FROM t');
      expect(rows.first.first, 2);
    });
    expect(await ids(), [1, 2]);
  });

  test('consulta pelo contexto da transação dentro do bloco', () async {
    await conn.transaction((ctx) async {
      await expectLater(
          ctx.savepoint((_) async {
            await ctx.query('SELECT 1/0');
          }),
          throwsA(isA<PostgreSQLException>()));
      await ctx.execute('INSERT INTO t VALUES (9)');
    });
    expect(await ids(), [9]);
  });

  test('exceção do código (sem erro de SQL) também desfaz o savepoint',
      () async {
    await conn.transaction((ctx) async {
      await expectLater(
          ctx.savepoint((sp) async {
            await sp.execute('INSERT INTO t VALUES (1)');
            throw StateError('regra de negócio');
          }),
          throwsStateError);
      await ctx.execute('INSERT INTO t VALUES (2)');
    });
    expect(await ids(), [2]);
  });

  test('savepoints aninhados', () async {
    await conn.transaction((ctx) async {
      await ctx.savepoint((outer) async {
        await outer.execute('INSERT INTO t VALUES (1)');
        await expectLater(
            outer.savepoint((inner) async {
              await inner.execute('INSERT INTO t VALUES (2)');
              await inner.execute('INSERT INTO t VALUES (2)');
            }),
            throwsA(isA<PostgreSQLException>()));
        await outer.execute('INSERT INTO t VALUES (3)');
      });
    });
    expect(await ids(), [1, 3]);
  });

  test('erro fora do savepoint continua desfazendo a transação', () async {
    await expectLater(
        conn.transaction((ctx) async {
          await ctx.savepoint((sp) => sp.execute('INSERT INTO t VALUES (1)'));
          await ctx.execute('INSERT INTO t VALUES (1)');
        }),
        throwsA(isA<PostgreSQLException>()));
    expect(await ids(), isEmpty);
    // Conexão continua utilizável.
    expect(await conn.query('SELECT 1'), [
      [1]
    ]);
  });

  test('erro não tratado do savepoint propagado pelo bloco desfaz tudo',
      () async {
    await expectLater(
        conn.transaction((ctx) async {
          await ctx.execute('INSERT INTO t VALUES (1)');
          await ctx.savepoint((sp) => sp.query('SELECT 1/0'));
        }),
        throwsA(isA<PostgreSQLException>()));
    expect(await ids(), isEmpty);
  });

  test('cancelTransaction dentro do savepoint desfaz a transação', () async {
    final result = await conn.transaction((ctx) async {
      await ctx.execute('INSERT INTO t VALUES (1)');
      await ctx.savepoint((sp) async {
        sp.cancelTransaction(reason: 'cancelado');
      });
    });
    expect(result, isA<PostgreSQLRollback>());
    expect(await ids(), isEmpty);
  });

  test('erro de consulta não aguardada depois do savepoint falha a transação',
      () async {
    await expectLater(
        conn.transaction((ctx) async {
          late Future<void> late_;
          await ctx.savepoint((sp) async {
            await sp.execute('INSERT INTO t VALUES (1)');
            // Começa dentro do bloco, mas só falha depois do RELEASE.
            late_ = Future<void>.delayed(const Duration(milliseconds: 50),
                () => sp.execute('INSERT INTO t VALUES (1)'));
          });
          await late_;
        }),
        throwsA(isA<PostgreSQLException>()));
    expect(await ids(), isEmpty);
  });

  test('savepoint fora de transação lança StateError', () {
    expect(() => conn.savepoint((_) async {}), throwsStateError);
  });

  test('COPY dentro de savepoint', () async {
    await conn.transaction((ctx) async {
      await expectLater(
          ctx.savepoint((sp) => sp.copyRows('t', [
                'id'
              ], [
                [1],
                [1]
              ])),
          throwsA(isA<PostgreSQLException>()
              .having((e) => e.code, 'code', PgErrorCode.uniqueViolation)));
      await ctx.copyRows('t', [
        'id'
      ], [
        [2]
      ]);
    });
    expect(await ids(), [2]);
  });
}
