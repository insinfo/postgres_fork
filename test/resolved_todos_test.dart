// Testes das pendências resolvidas na 3.0.0.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:postgres_fork/postgres.dart';
import 'package:postgres_fork/postgres_v3_experimental.dart';
import 'package:postgres_fork/src/logical_replication_messages.dart';
import 'package:test/test.dart';

import 'docker.dart';

final _endpoint = PgEndpoint(
    host: 'localhost',
    database: 'dart_test',
    username: 'dart',
    password: 'dart');

class _Money implements PostgresTextEncodable {
  final int cents;
  _Money(this.cents);

  @override
  String toPostgresText() =>
      '${cents ~/ 100}.${(cents % 100).toString().padLeft(2, '0')}';

  @override
  String get postgresTypeName => 'numeric';
}

void main() {
  usePostgresDocker();

  group('API v3: run, runTx e retry', () {
    late PgConnection conn;

    setUp(() async {
      conn = await PgConnection.open(_endpoint,
          sessionSettings: PgSessionSettings(onBadSslCertificate: (_) => true));
      await conn.execute('CREATE TEMP TABLE tx_items (i int)');
    });

    tearDown(() => conn.close());

    Future<int> count() async =>
        (await conn.execute('SELECT count(*)::int FROM tx_items'))
            .first
            .first as int;

    test('run entrega a própria conexão como sessão', () async {
      final result = await conn.run((session) async {
        return (await session.execute('SELECT 42')).first.first;
      });
      expect(result, 42);
    });

    test('runTx faz COMMIT ao terminar', () async {
      final result = await conn.runTx((session) async {
        await session.execute('INSERT INTO tx_items VALUES (1), (2)');
        return 'ok';
      });
      expect(result, 'ok');
      expect(await count(), 2);
    });

    test('runTx faz ROLLBACK e relança o erro', () async {
      await expectLater(
          conn.runTx((session) async {
            await session.execute('INSERT INTO tx_items VALUES (1)');
            throw StateError('falha da aplicação');
          }),
          throwsStateError);
      expect(await count(), 0);

      await expectLater(
          conn.runTx((session) async {
            await session.execute('INSERT INTO tx_items VALUES (1)');
            await session.execute('SELECT 1 / 0');
          }),
          throwsA(isA<PostgreSQLException>()
              .having((e) => e.code, 'code', '22012')));
      expect(await count(), 0);
    });

    test('operações de fora esperam a transação terminar', () async {
      final events = <String>[];
      final inside = Completer<void>();
      final tx = conn.runTx((session) async {
        await session.execute('INSERT INTO tx_items VALUES (1)');
        inside.complete();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        events.add('fim da transação');
      });
      await inside.future;
      final outside = count().then((value) {
        events.add('consulta externa: $value');
      });
      await Future.wait([tx, outside]);
      expect(events, ['fim da transação', 'consulta externa: 1']);
    });

    test('a sessão não pode ser usada depois da transação', () async {
      late PgSession saved;
      await conn.runTx((session) async {
        saved = session;
      });
      expect(() => saved.execute('SELECT 1'), throwsStateError);
    });

    test('retry repete a transação em falha de serialização', () async {
      var attempts = 0;
      final result = await conn.runTx((session) async {
        attempts++;
        await session.execute('INSERT INTO tx_items VALUES ($attempts)');
        if (attempts < 3) {
          await session.execute(
              "DO \$\$ BEGIN RAISE EXCEPTION 'conflito' "
              "USING ERRCODE = 'serialization_failure'; END \$\$");
        }
        return attempts;
      },
          retryOptions:
              const PgRetryOptions(delay: Duration(milliseconds: 10)));
      expect(result, 3);
      expect(await count(), 1);
    });

    test('sem retryOptions não repete; retryIf personalizado', () async {
      var attempts = 0;
      Future<void> failing(PgSession session) async {
        attempts++;
        await session.execute('SELECT 1 / 0');
      }

      await expectLater(
          conn.runTx(failing), throwsA(isA<PostgreSQLException>()));
      expect(attempts, 1);

      attempts = 0;
      await expectLater(
          conn.runTx(failing,
              retryOptions: PgRetryOptions(
                  maxAttempts: 4,
                  delay: Duration.zero,
                  retryIf: (e) =>
                      e is PostgreSQLException && e.code == '22012')),
          throwsA(isA<PostgreSQLException>()));
      expect(attempts, 4);
    });
  });

  group('API v2', () {
    late PostgreSQLConnection conn;

    setUp(() async {
      conn = PostgreSQLConnection('localhost', 5432, 'dart_test',
          username: 'dart', password: 'dart');
      await conn.open();
    });

    tearDown(() => conn.close());

    test('execute respeita o timeoutInSeconds informado', () async {
      await expectLater(
          conn.execute('SELECT pg_sleep(3)', timeoutInSeconds: 1),
          throwsA(isA<TimeoutException>()));
    });

    test('protocolo simples devolve NULL como null', () async {
      final rows = await conn.query("SELECT NULL::int, 'a', NULL::text",
          useSimpleQueryProtocol: true);
      expect(rows.first, [null, 'a', null]);
      expect(await conn.query('SELECT 1'), [
        [1]
      ]);
    });

    test('tipos da aplicação com PostgresTextEncodable', () async {
      final money = _Money(1250);
      // Como parâmetro sem tipo (texto).
      final param = await conn.query('SELECT @v::numeric',
          substitutionValues: {'v': money});
      expect(param.first.first, '12.50');
      // Inserido no SQL (protocolo simples): literal com cast.
      final inline = await conn.query('SELECT pg_typeof(@v)::text, @v',
          substitutionValues: {'v': money}, useSimpleQueryProtocol: true);
      expect(inline.first, ['numeric', '12.50']);
    });
  });

  test('TypeMessage.typeName', () {
    final bytes = Uint8List.fromList([
      0, 0, 0x40, 0x00, // OID
      ...utf8.encode('public'), 0,
      ...utf8.encode('humor'), 0,
    ]);
    final message = TypeMessage(bytes, utf8);
    expect(message.typeName, 'public.humor');
    final noSchema = TypeMessage(
        Uint8List.fromList([0, 0, 0, 1, 0, ...utf8.encode('t'), 0]), utf8);
    expect(noSchema.typeName, 't');
  });
}
