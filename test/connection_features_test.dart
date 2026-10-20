// Recursos da 3.0.0: limite de parâmetros, bytea, parâmetros de startup,
// CancelRequest, cache LRU, modos de SSL, LISTEN/NOTIFY, timestamp local e
// códigos SQLSTATE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:postgres_fork/postgres.dart';
import 'package:postgres_fork/postgres_v3_experimental.dart';
import 'package:test/test.dart';

import 'docker.dart';

PostgreSQLConnection _conn({
  String? applicationName,
  Map<String, String> startupParameters = const {},
  PgSslMode? sslMode,
  bool cancelQueryOnTimeout = false,
  int? maxPreparedStatements,
  DecodingSettings decodingSettings = const DecodingSettings(),
  int port = 5432,
}) =>
    PostgreSQLConnection('localhost', port, 'dart_test',
        username: 'dart',
        password: 'dart',
        applicationName: applicationName,
        startupParameters: startupParameters,
        sslMode: sslMode,
        cancelQueryOnTimeout: cancelQueryOnTimeout,
        maxPreparedStatements: maxPreparedStatements,
        decodingSettings: decodingSettings,
        timeoutInSeconds: 5);

void main() {
  usePostgresDocker();

  group('limite de 65535 parâmetros', () {
    test('API v2: erro claro e conexão utilizável', () async {
      final conn = _conn();
      await conn.open();
      addTearDown(conn.close);
      final count = 70000;
      final sql = 'SELECT ${List.filled(count, '?').join(', ')}';
      await expectLater(
          conn.query(sql,
              substitutionValues: List.filled(count, 1),
              placeholderIdentifier: PlaceholderIdentifier.onlyQuestionMark),
          throwsA(isA<PostgreSQLException>().having((e) => e.message,
              'message', contains('at most 65535'))));
      expect(await conn.query('SELECT 1'), [
        [1]
      ]);
    });

    test('API v3: erro claro antes de enviar', () async {
      final conn = await PgConnection.open(
          PgEndpoint(
              host: 'localhost',
              database: 'dart_test',
              username: 'dart',
              password: 'dart'),
          sessionSettings: PgSessionSettings(onBadSslCertificate: (_) => true));
      addTearDown(conn.close);
      final sql = 'SELECT ${List.generate(70000, (i) => '\$${i + 1}').join(', ')}';
      await expectLater(conn.execute(sql, parameters: List.filled(70000, 1)),
          throwsA(isA<PostgreSQLException>()));
      expect(await conn.execute('SELECT 1'), [
        [1]
      ]);
    });
  });

  test('Uint8List como parâmetro vira bytea', () async {
    final conn = _conn();
    await conn.open();
    addTearDown(conn.close);
    final bytes = Uint8List.fromList([0, 1, 127, 128, 255]);
    final typed = await conn.query('SELECT @b::bytea, length(@b::bytea)',
        substitutionValues: {'b': bytes});
    expect(typed.first, [bytes, 5]);
    final inline = await conn.query('SELECT @b, pg_typeof(@b)::text',
        substitutionValues: {'b': bytes}, useSimpleQueryProtocol: true);
    expect(inline.first, [r'\x00017f80ff', 'bytea']);
  });

  group('parâmetros de startup', () {
    test('API v2', () async {
      final conn = _conn(applicationName: 'sali-teste', startupParameters: {
        'search_path': 'pg_catalog,public',
        'statement_timeout': '1234',
      });
      await conn.open();
      addTearDown(conn.close);
      final row = (await conn.query("SELECT current_setting('application_name'), "
              "current_setting('search_path'), "
              "current_setting('statement_timeout')"))
          .first;
      expect(row, ['sali-teste', 'pg_catalog,public', '1234ms']);
    });

    test('API v3', () async {
      final conn = await PgConnection.open(
          PgEndpoint(
              host: 'localhost',
              database: 'dart_test',
              username: 'dart',
              password: 'dart'),
          sessionSettings: PgSessionSettings(
              onBadSslCertificate: (_) => true,
              applicationName: 'sali-v3',
              startupParameters: {'lock_timeout': '2s'}));
      addTearDown(conn.close);
      expect(
          await conn.execute("SELECT current_setting('application_name'), "
              "current_setting('lock_timeout')"),
          [
            ['sali-v3', '2s']
          ]);
    });

    test('parâmetros reservados são recusados', () {
      for (final name in ['user', 'TimeZone', 'client_encoding', '_pq_.x']) {
        expect(() => _conn(startupParameters: {name: 'x'}),
            throwsArgumentError);
      }
    });
  });

  group('CancelRequest', () {
    test('cancelQuery interrompe a consulta no servidor', () async {
      final conn = _conn();
      await conn.open();
      addTearDown(conn.close);
      final sw = Stopwatch()..start();
      final running = conn.query('SELECT pg_sleep(10)');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await conn.cancelQuery();
      await expectLater(
          running,
          throwsA(isA<PostgreSQLException>()
              .having((e) => e.code, 'code', PgErrorCode.queryCanceled)));
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
      expect(await conn.query('SELECT 1'), [
        [1]
      ]);
    });

    test('cancelQueryOnTimeout libera a conexão logo após o timeout',
        () async {
      final conn = _conn(cancelQueryOnTimeout: true);
      await conn.open();
      addTearDown(conn.close);
      final sw = Stopwatch()..start();
      await expectLater(
          conn.query('SELECT pg_sleep(8)', timeoutInSeconds: 1),
          throwsA(isA<TimeoutException>()));
      expect(await conn.query('SELECT 1'), [
        [1]
      ]);
      expect(sw.elapsed, lessThan(const Duration(seconds: 4)));
    });

    test('timeout de consulta ainda na fila não cancela a que está rodando',
        () async {
      final conn = _conn(cancelQueryOnTimeout: true);
      await conn.open();
      addTearDown(conn.close);
      final first = conn.query('SELECT pg_sleep(2), 1', timeoutInSeconds: 10);
      final queued = conn.query('SELECT 2', timeoutInSeconds: 1);
      await expectLater(queued, throwsA(isA<TimeoutException>()));
      final result = await first;
      expect(result.first[1], 1);
    });
  });

  group('cache LRU de prepared statements', () {
    test('limita os statements no servidor e mantém os resultados', () async {
      final conn = _conn(maxPreparedStatements: 3);
      await conn.open();
      addTearDown(conn.close);
      final random = Random(7);
      for (var i = 0; i < 300; i++) {
        final n = random.nextInt(10);
        final rows = await conn.query('SELECT $n + @v:int4',
            substitutionValues: {'v': i});
        expect(rows.first.first, n + i);
      }
      // O Close do último removido vai junto com a próxima consulta do
      // protocolo estendido: no máximo um statement a mais fica pendente.
      var prepared = await conn.query(
          'SELECT count(*)::int FROM pg_prepared_statements',
          useSimpleQueryProtocol: true);
      expect(int.parse(prepared.first.first as String), lessThanOrEqualTo(4));
      await conn.query('SELECT 1');
      prepared = await conn.query(
          'SELECT count(*)::int FROM pg_prepared_statements',
          useSimpleQueryProtocol: true);
      expect(int.parse(prepared.first.first as String), lessThanOrEqualTo(4));
    });

    test('sem limite (padrão) mantém todos', () async {
      final conn = _conn();
      await conn.open();
      addTearDown(conn.close);
      for (var n = 0; n < 10; n++) {
        await conn.query('SELECT $n');
      }
      final prepared = await conn.query(
          'SELECT count(*)::int FROM pg_prepared_statements',
          useSimpleQueryProtocol: true);
      expect(int.parse(prepared.first.first as String), 10);
    });
  });

  group('modos de SSL', () {
    Future<bool?> usesSsl(PgSslMode mode) async {
      final conn = _conn(sslMode: mode);
      await conn.open();
      try {
        final rows = await conn.query(
            'SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()');
        return rows.first.first as bool?;
      } finally {
        await conn.close();
      }
    }

    test('disable, prefer e require com servidor que aceita SSL', () async {
      expect(await usesSsl(PgSslMode.disable), isFalse);
      expect(await usesSsl(PgSslMode.prefer), isTrue);
      expect(await usesSsl(PgSslMode.require), isTrue);
    });

    test('verifyFull recusa certificado não confiável', () async {
      final conn = _conn(sslMode: PgSslMode.verifyFull);
      await expectLater(conn.open(), throwsA(anything));
    });

    test('prefer continua sem SSL quando o servidor recusa', () async {
      // Servidor falso: responde "N" ao SSLRequest e um erro à mensagem de
      // startup (que só chega se o cliente seguir sem SSL).
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((socket) {
        var step = 0;
        socket.listen((data) {
          if (step++ == 0) {
            socket.add([0x4E]); // 'N'
          } else {
            final fields = <int>[
              ...[0x53, ...utf8.encode('FATAL'), 0],
              ...[0x43, ...utf8.encode('28000'), 0],
              ...[0x4D, ...utf8.encode('fake server'), 0],
              0,
            ];
            socket.add([
              0x45,
              ...(ByteData(4)..setInt32(0, fields.length + 4))
                  .buffer
                  .asUint8List(),
              ...fields,
            ]);
            socket.close();
          }
        });
      });
      final prefer = _conn(sslMode: PgSslMode.prefer, port: server.port);
      await expectLater(
          prefer.open(),
          throwsA(isA<PostgreSQLException>()
              .having((e) => e.message, 'message', 'fake server')));
      final require = _conn(sslMode: PgSslMode.require, port: server.port);
      await expectLater(
          require.open(),
          throwsA(isA<PostgreSQLException>().having(
              (e) => e.message, 'message', contains('not accepting SSL'))));
    });
  });

  test('LISTEN/NOTIFY', () async {
    final conn = _conn();
    await conn.open();
    addTearDown(conn.close);
    await conn.listen('canal "especial"');
    final received = conn.notificationsFor('canal "especial"').first;
    await conn.notify('canal "especial"', 'olá');
    final n = await received.timeout(const Duration(seconds: 5));
    expect(n.payload, 'olá');
    expect(n.processID, conn.processID);
    await conn.unlisten();
  });

  test('timestamp e date como horário local', () async {
    final conn = _conn(
        decodingSettings: const DecodingSettings(
            timestamp: TimestampDecoding.localWallClock));
    await conn.open();
    addTearDown(conn.close);
    final row = (await conn.query(
            "SELECT '2024-01-15 10:30:45.123456'::timestamp, "
            "'2024-07-01'::date, 'infinity'::timestamp, "
            "ARRAY['2024-02-29 23:59:59'::timestamp]"))
        .first;
    expect(row[0], DateTime(2024, 1, 15, 10, 30, 45, 123, 456));
    expect((row[0] as DateTime).isUtc, isFalse);
    expect(row[1], DateTime(2024, 7, 1));
    expect(row[2], isNull);
    expect(row[3], [DateTime(2024, 2, 29, 23, 59, 59)]);
  });

  test('PgErrorCode com violação de unicidade', () async {
    final conn = _conn();
    await conn.open();
    addTearDown(conn.close);
    await conn.execute(
        'CREATE TEMP TABLE uniq (id int CONSTRAINT uniq_pk PRIMARY KEY)');
    await conn.execute('INSERT INTO uniq VALUES (1)');
    await expectLater(
        conn.execute('INSERT INTO uniq VALUES (1)'),
        throwsA(isA<PostgreSQLException>()
            .having((e) => e.code, 'code', PgErrorCode.uniqueViolation)
            .having((e) => e.constraintName, 'constraint', 'uniq_pk')));
  });
}
