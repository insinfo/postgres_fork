// Matriz de cobertura: cada ponto de entrada da API (v2: query, execute,
// mappedResultsQuery, queryAsMap, transaction, pool; v3: execute, prepare,
// runTx, pool) × cada tipo de comando (SELECT com e sem linhas, DDL, SET, DO
// com NOTICE, DROP IF EXISTS com NOTICE, INSERT com e sem RETURNING, UPDATE,
// DELETE, comando vazio, SHOW, LISTEN), a frio e a quente (statement
// reutilizado). Depois de cada chamada, o PRÓXIMO comando na mesma conexão
// precisa devolver o próprio resultado.

import 'dart:async';

import 'package:postgres_fork/messages.dart';
import 'package:postgres_fork/postgres.dart';
import 'package:postgres_fork/postgres_v3_experimental.dart';
import 'package:test/test.dart';

import 'docker.dart';

const _table = 'cov_matrix';

PostgreSQLConnection _conn({int queryTimeout = 10}) =>
    PostgreSQLConnection('localhost', 5432, 'dart_test',
        username: 'dart',
        password: 'dart',
        timeoutInSeconds: 5,
        queryTimeoutInSeconds: queryTimeout);

final _endpoint = PgEndpoint(
    host: 'localhost',
    database: 'dart_test',
    username: 'dart',
    password: 'dart');
final _settings = PgSessionSettings(onBadSslCertificate: (_) => true);

/// Um tipo de comando e o que se espera dele.
class _Kind {
  const _Kind(this.name, this.sql,
      {this.rows = const [], this.count = 0, this.notice = false});

  final String name;
  final String sql;

  /// Linhas esperadas, com os valores como texto (o protocolo simples
  /// devolve texto). Null: não verifica.
  final List<List<String>>? rows;
  final int count;

  /// Se o servidor envia um NOTICE.
  final bool notice;
}

const _kinds = [
  _Kind('SELECT com linhas', 'SELECT 1 AS a UNION ALL SELECT 2',
      rows: [
        ['1'],
        ['2']
      ],
      count: 2),
  _Kind('SELECT sem linhas', 'SELECT 1 AS a WHERE false'),
  _Kind('DDL', 'CREATE TEMP TABLE IF NOT EXISTS cov_matrix_tmp (a int)'),
  _Kind('SET', "SET application_name = 'cov_matrix'"),
  _Kind('DO com NOTICE', r"DO $$ BEGIN RAISE NOTICE 'cov'; END $$",
      notice: true),
  _Kind('DROP IF EXISTS com NOTICE', 'DROP TABLE IF EXISTS cov_matrix_nope',
      notice: true),
  _Kind('INSERT sem RETURNING', 'INSERT INTO $_table (v) VALUES (1)', count: 1),
  _Kind(
      'INSERT com RETURNING', 'INSERT INTO $_table (v) VALUES (2) RETURNING v',
      rows: [
        ['2']
      ],
      count: 1),
  _Kind('UPDATE sem linhas afetadas', 'UPDATE $_table SET v = v WHERE v < 0'),
  _Kind('DELETE sem linhas afetadas', 'DELETE FROM $_table WHERE v < 0'),
  _Kind('comando vazio', ''),
  _Kind('SHOW', 'SHOW server_version_num', rows: null),
  _Kind('LISTEN', 'LISTEN cov_matrix_chan'),
];

List<List<String>> _text(Iterable<List<Object?>> rows) =>
    [for (final r in rows) r.map((v) => '$v').toList()];

/// Conta os NOTICE recebidos pela conexão (chegam em [messages] como
/// mensagens desconhecidas com o código 'N').
class _Notices {
  _Notices(PostgreSQLConnection c) {
    _sub = c.messages.listen((m) {
      if (m is UnknownMessage && m.code == 78) count++;
    });
  }

  late final StreamSubscription<ServerMessage> _sub;
  int count = 0;

  Future<void> cancel() => _sub.cancel();
}

var _marker = 0;

/// O próximo comando na conexão devolve o próprio resultado.
Future<void> _expectNext(PostgreSQLExecutionContext c) async {
  final m = ++_marker;
  final r =
      await c.query('SELECT @m::int AS marker', substitutionValues: {'m': m});
  expect(r, [
    [m]
  ]);
  expect(r.columnDescriptions.single.columnName, 'marker');
  expect(await c.execute('SELECT $m UNION ALL SELECT $m'), 2);
}

typedef _Runner = Future<void> Function(
    PostgreSQLExecutionContext c, _Kind kind);

/// Executa [kind] pela API e confere resultado e linhas afetadas.
final Map<String, _Runner> _v2Apis = {
  'query (allowReuse)': (c, k) async {
    final r = await c.query(k.sql);
    expect(r.affectedRowCount, k.count);
    if (k.rows != null) expect(_text(r), k.rows);
  },
  'query (allowReuse: false)': (c, k) async {
    final r = await c.query(k.sql, allowReuse: false);
    expect(r.affectedRowCount, k.count);
    if (k.rows != null) expect(_text(r), k.rows);
  },
  'query (useSimpleQueryProtocol)': (c, k) async {
    final r = await c.query(k.sql, useSimpleQueryProtocol: true);
    expect(r.affectedRowCount, k.count);
    if (k.rows != null) expect(_text(r), k.rows);
  },
  'execute': (c, k) async {
    expect(await c.execute(k.sql), k.count);
  },
  'mappedResultsQuery': (c, k) async {
    final r = await c.mappedResultsQuery(k.sql);
    if (k.rows != null) expect(r.length, k.rows!.length);
  },
  'queryAsMap': (c, k) async {
    final r = await c.queryAsMap(k.sql);
    if (k.rows != null) {
      expect([for (final m in r) m.values.map((v) => '$v').toList()], k.rows);
    }
  },
};

void main() {
  usePostgresDocker();

  late PostgreSQLConnection setup;

  setUpAll(() async {
    setup = _conn();
    await setup.open();
    await setup.execute('DROP TABLE IF EXISTS $_table');
    await setup.execute('CREATE TABLE $_table (id serial PRIMARY KEY, v int)');
  });

  tearDownAll(() async {
    await setup.execute('DROP TABLE IF EXISTS $_table');
    await setup.close();
  });

  group('API v2 × tipo de comando', () {
    for (final api in _v2Apis.entries) {
      group(api.key, () {
        late PostgreSQLConnection c;
        late _Notices notices;

        setUpAll(() async {
          c = _conn();
          await c.open();
          notices = _Notices(c);
        });

        tearDownAll(() async {
          await notices.cancel();
          await c.close();
        });

        for (final kind in _kinds) {
          test(kind.name, () async {
            for (var round = 0; round < 2; round++) {
              // A frio (round 0) e a quente (statement reutilizado).
              final before = notices.count;
              await api.value(c, kind);
              await _expectNext(c);
              if (kind.notice) expect(notices.count, greaterThan(before));
            }
          });
        }
      });
    }

    group('dentro de transaction()', () {
      late PostgreSQLConnection c;

      setUpAll(() async {
        c = _conn();
        await c.open();
      });

      tearDownAll(() => c.close());

      for (final api in _v2Apis.entries) {
        test(api.key, () async {
          final outside = <Future<void>>[];
          final result = await c.transaction((ctx) async {
            for (final kind in _kinds) {
              if (kind.sql.startsWith('SET')) continue;
              for (var round = 0; round < 2; round++) {
                await api.value(ctx, kind);
                await _expectNext(ctx);
              }
              // Chamadas de fora esperam a transação (não rodam dentro).
              outside.add(c
                  .query('SELECT txid_current_if_assigned() IS NULL')
                  .then((r) => expect(r.single.single, isTrue)));
            }
            return 'ok';
          });
          expect(result, 'ok');
          await Future.wait(outside);
          await _expectNext(c);
        });
      }
    });

    group('PostgreSQLPool', () {
      late PostgreSQLPool pool;

      setUpAll(() {
        pool = PostgreSQLPool(_conn,
            settings: const PostgreSQLPoolSettings(maxConnectionCount: 2));
      });

      tearDownAll(() => pool.close(force: true));

      for (final api in _v2Apis.entries) {
        test(api.key, () async {
          for (final kind in _kinds) {
            for (var round = 0; round < 2; round++) {
              await api.value(pool, kind);
              await _expectNext(pool);
              // Na mesma conexão do pool.
              await pool.withConnection((c) async {
                await api.value(c, kind);
                await _expectNext(c);
              });
            }
          }
          expect(pool.status.connectionCount, lessThanOrEqualTo(2));
        });
      }
    });
  });

  group('API v2: cache de statements e protocolo', () {
    late PostgreSQLConnection c;

    setUp(() async {
      c = _conn();
      await c.open();
    });

    tearDown(() => c.close());

    Future<int> preparedCount() async =>
        (await c.query('SELECT count(*)::int FROM pg_prepared_statements',
                allowReuse: false))
            .single
            .single as int;

    test('comandos sem linhas reutilizam um único prepared statement',
        () async {
      // Regressão: o statement nunca entrava no cache (NoData) e cada
      // execução com allowReuse preparava outro statement nomeado.
      const kinds = [
        'INSERT INTO $_table (v) VALUES (10)',
        'UPDATE $_table SET v = 11 WHERE v = 10',
        'DELETE FROM $_table WHERE v = 11',
        "SET application_name = 'cov_reuse'",
        'CREATE TEMP TABLE IF NOT EXISTS cov_matrix_reuse (a int)',
      ];
      for (final sql in kinds) {
        await c.query(sql);
      }
      final after1 = await preparedCount();
      for (var i = 0; i < 5; i++) {
        for (final sql in kinds) {
          await c.query(sql);
        }
      }
      expect(await preparedCount(), after1);
    });

    test('vários comandos no protocolo simples: vale o último resultado',
        () async {
      // Regressão: as linhas dos dois SELECT ficavam juntas com a descrição
      // de colunas do último (toColumnMap lançava RangeError).
      final r = await c.query('SELECT 1 AS a; SELECT 2 AS b, 3 AS c',
          useSimpleQueryProtocol: true);
      expect(r.map((row) => row.toColumnMap()).toList(), [
        {'b': '2', 'c': '3'}
      ]);
      expect(
          await c.execute('INSERT INTO $_table (v) VALUES (20), (20); '
              'DELETE FROM $_table WHERE v = 20'),
          2);
      final last = await c.query(
          'SELECT 1 AS a; INSERT INTO $_table (v) VALUES (21); '
          'DELETE FROM $_table WHERE v = 21',
          useSimpleQueryProtocol: true);
      expect(last.affectedRowCount, 1);
      await _expectNext(c);
    });

    test('settings acompanha SET (ParameterStatus)', () async {
      await c.execute("SET application_name = 'cov_matrix_settings'");
      expect(c.settings['application_name'], 'cov_matrix_settings');
      await c.query("SET TimeZone = 'America/Sao_Paulo'");
      expect(c.settings['TimeZone'], 'America/Sao_Paulo');
      await c.transaction((ctx) async {
        await ctx.execute("SET LOCAL application_name = 'cov_local'");
        expect(c.settings['application_name'], 'cov_local');
      });
      // O COMMIT desfaz o SET LOCAL.
      expect(c.settings['application_name'], 'cov_matrix_settings');
    });

    test('statement em cache depois de ALTER TABLE muda o resultado', () async {
      await c.execute('CREATE TEMP TABLE cov_matrix_alter (a int)');
      await c.execute('INSERT INTO cov_matrix_alter VALUES (1)');
      const sql = 'SELECT * FROM cov_matrix_alter';
      expect(await c.query(sql), [
        [1]
      ]);
      await c.execute('ALTER TABLE cov_matrix_alter ADD COLUMN b int');
      // O servidor recusa o plano em cache (0A000) uma vez; antes o
      // statement ficava no cache e toda execução seguinte falhava.
      await expectLater(
          c.query(sql),
          throwsA(isA<PostgreSQLException>()
              .having((e) => e.code, 'code', '0A000')));
      expect(await c.query(sql), [
        [1, null]
      ]);
      expect(await c.query(sql), [
        [1, null]
      ]);
    });

    test('DEALLOCATE ALL e DISCARD ALL limpam o cache', () async {
      const sql = 'SELECT 7 AS sete';
      for (final reset in ['DEALLOCATE ALL', 'DISCARD ALL']) {
        expect(await c.query(sql), [
          [7]
        ]);
        await c.execute(reset);
        // Antes: 26000 (prepared statement does not exist) para sempre.
        expect(await c.query(sql), [
          [7]
        ]);
        // O próprio comando, executado por query() (prepared statement).
        await c.query(reset);
        await c.query(reset);
        expect(await c.query(sql), [
          [7]
        ]);
      }
    });

    test('statement removido por fora (DEALLOCATE nome) volta a ser preparado',
        () async {
      const sql = 'SELECT 8 AS oito';
      expect(await c.query(sql), [
        [8]
      ]);
      final name = (await c.query(
              'SELECT name FROM pg_prepared_statements WHERE statement = @s',
              substitutionValues: {'s': sql},
              allowReuse: false))
          .single
          .single as String;
      await c.execute('DEALLOCATE "$name"');
      await expectLater(
          c.query(sql),
          throwsA(isA<PostgreSQLException>()
              .having((e) => e.code, 'code', '26000')));
      expect(await c.query(sql), [
        [8]
      ]);
      // Dentro de uma transação o erro desfaz a transação; depois dela o
      // statement funciona.
      final name2 = (await c.query(
              'SELECT name FROM pg_prepared_statements WHERE statement = @s',
              substitutionValues: {'s': sql},
              allowReuse: false))
          .single
          .single as String;
      await c.execute('DEALLOCATE "$name2"');
      await expectLater(
          c.transaction((ctx) => ctx.query(sql)),
          throwsA(isA<PostgreSQLException>()
              .having((e) => e.code, 'code', '26000')));
      expect(await c.query(sql), [
        [8]
      ]);
    });

    test('vários casts depois do placeholder', () async {
      // Antes '@d::timestamptz::text' virava '$1::timestamptztext'.
      final r = await c.query('SELECT @d::timestamptz::date::text',
          substitutionValues: {'d': DateTime.utc(2024, 1, 15, 12)});
      expect(r, [
        ['2024-01-15']
      ]);
      final simple =
          await c.execute('SELECT @n::int::text', substitutionValues: {'n': 5});
      expect(simple, 1);
    });

    test('protocolo simples: arrays, pontos e números negativos no SQL',
        () async {
      Future<Object?> simple(String sql, Map<String, Object?> values) async =>
          (await c.query(sql,
                  substitutionValues: values, useSimpleQueryProtocol: true))
              .single
              .single;

      // Antes: '{1,2}' e '(1.5, 2)' sem aspas (erro de sintaxe / record).
      expect(
          await simple('SELECT @a::int[]::text', {
            'a': [1, 2]
          }),
          '{1,2}');
      expect(
          await simple('SELECT @a::text[]::text', {
            'a': ['x', "o'k", r'b\c']
          }),
          '{x,o\'k,"b\\\\c"}');
      expect(
          await simple('SELECT @p::point::text', {'p': const PgPoint(1.5, -2)}),
          '(1.5,-2)');
      // '5-@x' com x = -1 virava '5--1' (comentário); -32768 virava
      // -(32768::int2), fora do intervalo.
      expect(await simple('SELECT 5-@x', {'x': -1}), '6');
      expect(await simple('SELECT @x::int2', {'x': -32768}), '-32768');
      expect(await simple('SELECT @x::text', {'x': -1.5}), '-1.5');
      expect(await simple('SELECT @x::int8', {'x': -9223372036854775808}),
          '-9223372036854775808');
      expect(
          await simple('SELECT 1 = ANY(@a)', {
            'a': [3, 1]
          }),
          't');
      expect(
          await c.execute('SELECT 1 WHERE 1 = ANY(@a)', substitutionValues: {
            'a': [1]
          }),
          1);
    });

    test('mappedResultsQuery com view e tabela associa os nomes pelo OID',
        () async {
      await c.execute('DROP VIEW IF EXISTS cov_matrix_v');
      await c.execute('DROP TABLE IF EXISTS cov_matrix_t');
      // A view tem OID menor que a tabela: antes o nome da tabela era
      // associado ao OID da view (pela posição).
      await c.execute('CREATE VIEW cov_matrix_v AS SELECT 1 AS vid');
      await c.execute('CREATE TABLE cov_matrix_t (id int)');
      addTearDown(() async {
        await setup.execute('DROP VIEW IF EXISTS cov_matrix_v');
        await setup.execute('DROP TABLE IF EXISTS cov_matrix_t');
      });
      await c.execute('INSERT INTO cov_matrix_t VALUES (1)');
      final other = _conn();
      await other.open();
      addTearDown(other.close);
      expect(
          await other.mappedResultsQuery(
              'SELECT t.id, v.vid FROM cov_matrix_t t, cov_matrix_v v'),
          [
            {
              'cov_matrix_t': {'id': 1},
              '': {'vid': 1}
            }
          ]);
    });

    test('nomes de coluna fora do ASCII', () async {
      // Antes cada byte virava um caractere ("descriÃ§Ã£o").
      const sql = 'SELECT 1 AS "descrição", 2 AS "日本"';
      expect(
          (await c.query(sql)).single.toColumnMap(), {'descrição': 1, '日本': 2});
      expect(
          (await c.query(sql, useSimpleQueryProtocol: true))
              .single
              .toColumnMap(),
          {'descrição': '1', '日本': '2'});
      expect(await c.queryAsMap(sql), [
        {'descrição': 1, '日本': 2}
      ]);
    });

    test('maxPreparedStatements com cache invalidado', () async {
      final small = PostgreSQLConnection('localhost', 5432, 'dart_test',
          username: 'dart', password: 'dart', maxPreparedStatements: 2);
      await small.open();
      addTearDown(small.close);
      for (var round = 0; round < 3; round++) {
        for (var i = 0; i < 4; i++) {
          expect(await small.query('SELECT $i AS n'), [
            [i]
          ]);
        }
        await small.execute('DISCARD ALL');
      }
      expect(
          (await small.query('SELECT count(*)::int FROM pg_prepared_statements',
                  allowReuse: false))
              .single
              .single,
          lessThanOrEqualTo(3));
    });
  });

  group('concorrência numa conexão (API v2)', () {
    late PostgreSQLConnection c;

    setUp(() async {
      c = _conn();
      await c.open();
      await c.execute('DELETE FROM $_table');
    });

    tearDown(() => c.close());

    test('muitas consultas e transações: ordem, sem vazamento, erros isolados',
        () async {
      final order = <int>[];
      final futures = <Future<Object?>>[];
      for (var i = 0; i < 80; i++) {
        if (i % 10 == 3) {
          futures.add(c.transaction((ctx) async {
            await ctx.query(
                'INSERT INTO $_table (id, v) VALUES (@i + 100000, @i)',
                substitutionValues: {'i': i});
            order.add(i);
            return (await ctx
                    .query('SELECT txid_current_if_assigned() IS NOT NULL'))
                .single
                .single;
          }));
        } else if (i % 10 == 7) {
          futures.add(c.transaction((ctx) async {
            await ctx.query(
                'INSERT INTO $_table (id, v) VALUES (@i + 100000, @i)',
                substitutionValues: {'i': i});
            order.add(i);
            await ctx.query('SELECT 1/0');
          }).then<Object?>((_) => 'committed?',
              onError: (Object e) => (e as PostgreSQLException).code));
        } else if (i.isEven) {
          futures.add(c.query(
              'SELECT @i::int, txid_current_if_assigned() IS NULL',
              substitutionValues: {'i': i}).then((r) {
            order.add(i);
            return r.single.toList();
          }));
        } else {
          futures.add(c.execute('SELECT @i::int',
              substitutionValues: {'i': i}).then((n) {
            order.add(i);
            return n;
          }));
        }
      }
      final results = await Future.wait(futures);
      for (var i = 0; i < 80; i++) {
        if (i % 10 == 3) {
          expect(results[i], isTrue);
        } else if (i % 10 == 7) {
          expect(results[i], '22012');
        } else if (i.isEven) {
          expect(results[i], [i, true]);
        } else {
          expect(results[i], 1);
        }
      }
      // Ordem de chegada (FIFO), inclusive das transações.
      expect(order, List.generate(80, (i) => i));
      expect(await c.query('SELECT v FROM $_table ORDER BY v'), [
        for (var i = 0; i < 80; i++)
          if (i % 10 == 3) [i]
      ]);
    });

    test('chamadas de fora esperam a transação e não rodam dentro dela',
        () async {
      final events = <String>[];
      final started = Completer<void>();
      final tx = c.transaction((ctx) async {
        await ctx.query('INSERT INTO $_table (v) VALUES (500)');
        started.complete();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        events.add('tx');
        await ctx.query('INSERT INTO $_table (v) VALUES (501)');
        throw StateError('falha da aplicação');
      });
      await started.future;
      final outside = [
        c.query('SELECT count(*)::int FROM $_table').then((r) {
          events.add('outside');
          return r.single.single;
        }),
        c.execute('INSERT INTO $_table (v) VALUES (502)').then((n) {
          events.add('outside');
          return n;
        }),
      ];
      await expectLater(tx, throwsA(isA<StateError>()));
      // Rodaram depois do ROLLBACK: nada da transação ficou.
      expect(await Future.wait(outside), [0, 1]);
      expect(events, ['tx', 'outside', 'outside']);
      expect(await c.query('SELECT v FROM $_table'), [
        [502]
      ]);
    });

    test('erro de SQL na transação com chamadas de fora esperando', () async {
      final waiting = <Future<Object?>>[];
      final tx = c.transaction((ctx) async {
        for (var i = 0; i < 5; i++) {
          waiting.add(c.query('SELECT @i::int', substitutionValues: {'i': i}));
        }
        await ctx.query('INSERT INTO $_table (v) VALUES (600)');
        // Consultas da transação na fila depois da que falha.
        final queued = [
          ctx.query('SELECT 1/0'),
          ctx.query('SELECT 2'),
          ctx.query('SELECT 3'),
        ];
        await Future.wait(queued);
      });
      await expectLater(
          tx,
          throwsA(isA<PostgreSQLException>()
              .having((e) => e.code, 'code', '22012')));
      final results = await Future.wait(waiting);
      expect(results.map((r) => (r as PostgreSQLResult).single.single),
          [0, 1, 2, 3, 4]);
      expect(await c.query('SELECT count(*)::int FROM $_table'), [
        [0]
      ]);
    });

    test('transações em sequência não se misturam', () async {
      final results = await Future.wait([
        for (var t = 0; t < 10; t++)
          c.transaction((ctx) async {
            final txid =
                (await ctx.query('SELECT txid_current()::text')).single.single;
            await Future<void>.delayed(Duration(milliseconds: 10 - t));
            for (var i = 0; i < 3; i++) {
              final again = (await ctx.query('SELECT txid_current()::text'))
                  .single
                  .single;
              expect(again, txid);
            }
            return txid;
          }),
      ]);
      expect(results.toSet().length, 10);
    });
  });

  group('API v3 × tipo de comando', () {
    late PgConnection v;

    setUpAll(() async {
      v = await PgConnection.open(_endpoint, sessionSettings: _settings);
    });

    tearDownAll(() => v.close());

    Future<void> expectNextV3(PgSession s) async {
      final m = ++_marker;
      expect(await s.execute('SELECT $m AS marker'), [
        [m]
      ]);
      expect(
          await s.execute(PgSql(r'SELECT $1::int', types: [PgDataType.integer]),
              parameters: [m]),
          [
            [m]
          ]);
    }

    for (final kind in _kinds) {
      test('execute: ${kind.name}', () async {
        for (var round = 0; round < 2; round++) {
          final r = await v.execute(kind.sql);
          expect(r.affectedRows, kind.count);
          if (kind.rows != null) expect(_text(r), kind.rows);
          await expectNextV3(v);
        }
      });
    }

    test('execute com parâmetros e prepare/run reutilizado', () async {
      final insert = PgSql(r'INSERT INTO cov_matrix (v) VALUES ($1)',
          types: [PgDataType.integer]);
      final r = await v.execute(insert, parameters: [700]);
      expect(r.affectedRows, 1);
      expect(r, isEmpty);
      await expectNextV3(v);
      final stmt = await v.prepare(PgSql(
          r'UPDATE cov_matrix SET v = $1 WHERE v = $2 RETURNING v',
          types: [PgDataType.integer, PgDataType.integer]));
      final updated = await stmt.run([701, 700]);
      expect(updated.affectedRows, 1);
      expect(updated, [
        [701]
      ]);
      final none = await stmt.run([702, 700]);
      expect(none.affectedRows, 0);
      expect(none, isEmpty);
      await stmt.dispose();
      await expectNextV3(v);
      final del = await v.execute(
          PgSql(r'DELETE FROM cov_matrix WHERE v = $1',
              types: [PgDataType.integer]),
          parameters: [701]);
      expect(del.affectedRows, 1);
    });

    test('runTx: tipos de comando, chamadas de fora esperam', () async {
      final outside = <Future<PgResult>>[];
      await v.runTx((s) async {
        for (final kind in _kinds) {
          final r = await s.execute(kind.sql);
          expect(r.affectedRows, kind.count);
          await expectNextV3(s);
          outside.add(v.execute('SELECT txid_current_if_assigned() IS NULL'));
        }
      });
      for (final r in await Future.wait(outside)) {
        expect(r.single.single, isTrue);
      }
    });

    test('vários comandos numa consulta simples', () async {
      // Antes: "Future already completed" sem tratamento.
      final r = await v.execute('SELECT 1 AS a; SELECT 2 AS b, 3 AS c');
      expect(r, [
        [1],
        [2, 3]
      ]);
      expect(r.schema.columns.single.columnName, 'a');
      expect(r[1].schema.columns.map((c) => c.columnName), ['b', 'c']);
      final ddl = await v.execute('CREATE TEMP TABLE cov_matrix_v3 (a int); '
          'INSERT INTO cov_matrix_v3 VALUES (1), (2)');
      expect(ddl.affectedRows, 2);
      await expectNextV3(v);
    });

    test('formato texto: tipos sem decodificador de texto vêm como String',
        () async {
      // Consultas sem parâmetros usam o protocolo simples; antes date,
      // timestamptz, numeric, uuid, json... falhavam com UnimplementedError.
      final r = await v.execute("SELECT '2024-01-15'::date, 1.50::numeric, "
          "'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid, "
          "'{\"a\":1}'::jsonb, '2024-01-15 10:00:00+00'::timestamptz, "
          "'{1,2}'::int[], 42, 'x'::text, true");
      expect(r.single, [
        '2024-01-15',
        '1.50',
        'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11',
        '{"a": 1}',
        isA<String>(),
        '{1,2}',
        42,
        'x',
        true,
      ]);
      await expectNextV3(v);
    });

    test('parâmetro que não pode ser codificado falha sem travar', () async {
      // Antes: o erro escapava sem tratamento e a chamada nunca terminava.
      await expectLater(
          v.execute(PgSql(r'SELECT $1::int', types: [PgDataType.integer]),
              parameters: ['não é int']).timeout(const Duration(seconds: 5)),
          throwsA(isA<FormatException>()));
      await expectNextV3(v);
      expect(
          await v.execute('SELECT count(*)::int FROM pg_prepared_statements'), [
        [0]
      ]);
    });

    test('PgPool (v3)', () async {
      final pool = await PgPool.open([_endpoint],
          sessionSettings: _settings,
          poolSettings: PgPoolSettings(maxConnectionCount: 2));
      addTearDown(pool.close);
      for (final kind in _kinds) {
        final r = await pool.execute(kind.sql);
        expect(r.affectedRows, kind.count);
        await pool.withConnection(expectNextV3);
        await pool.runTx((s) async {
          await s.execute(kind.sql);
          await expectNextV3(s);
        });
      }
    });
  });
}
