// PgConnection (postgres_v3_experimental.dart) must not wait forever on a server
// that goes away or never answers: open() and the operation waiting for a reply
// end with an error, and a failed open() closes its socket.
//
// Fake servers on loopback, no database needed. The TLS ones use the
// certificates in test/fixtures/tls.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:postgres_fork/postgres.dart' show PostgreSQLException;
import 'package:postgres_fork/postgres_v3_experimental.dart';
import 'package:test/test.dart';

const _dir = 'test/fixtures/tls';

/// What the fake server does with the first message after the SSL negotiation
/// (the startup message).
enum _OnStartup { close, ignore, acceptThenCloseOnQuery }

class _FakeServer {
  _FakeServer._(this._socket, this._tls, this._onStartup) {
    _socket.listen(_serve);
  }

  static Future<_FakeServer> start(
      {required bool tls, required _OnStartup onStartup}) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    return _FakeServer._(server, tls, onStartup);
  }

  final ServerSocket _socket;
  final bool _tls;
  final _OnStartup _onStartup;

  /// Completes when the client closes the connection.
  final clientClosed = Completer<void>();

  int get port => _socket.port;

  /// AuthenticationOk followed by ReadyForQuery (idle).
  static final _ready = Uint8List.fromList([
    0x52, 0, 0, 0, 8, 0, 0, 0, 0, // 'R'
    0x5A, 0, 0, 0, 5, 0x49, // 'Z'
  ]);

  void _serve(Socket client) {
    // ignore: cancel_subscriptions
    late StreamSubscription<Uint8List> sub;
    var negotiated = false;
    sub = client.listen((chunk) async {
      if (negotiated) {
        _onMessage(client, client.add);
        return;
      }
      negotiated = true;
      if (!_tls) {
        client.add([0x4E]); // 'N'
        return;
      }
      sub.pause();
      client.add([0x53]); // 'S'
      await client.flush();
      final secure = await SecureSocket.secureServer(
          client,
          SecurityContext()
            ..useCertificateChain('$_dir/server.pem')
            ..usePrivateKey('$_dir/server-key.pem'));
      secure.listen((_) => _onMessage(secure, secure.add),
          onDone: _clientClosed, onError: (_) {});
    }, onDone: _clientClosed, onError: (_) {});
  }

  var _messages = 0;

  void _onMessage(Socket socket, void Function(List<int>) send) {
    _messages++;
    switch (_onStartup) {
      case _OnStartup.close:
        socket.destroy();
      case _OnStartup.ignore:
        break;
      case _OnStartup.acceptThenCloseOnQuery:
        if (_messages == 1) {
          send(_ready);
        } else {
          socket.destroy();
        }
    }
  }

  void _clientClosed() {
    if (!clientClosed.isCompleted) clientClosed.complete();
  }

  Future<void> close() => _socket.close();
}

Future<PgConnection> _open(int port,
        {Duration connectTimeout = const Duration(seconds: 2)}) =>
    PgConnection.open(
        PgEndpoint(
            host: 'localhost',
            port: port,
            database: 'db',
            username: 'u',
            password: 'p'),
        sessionSettings: PgSessionSettings(
            connectTimeout: connectTimeout,
            onBadSslCertificate: (_) => true));

/// Far above the connect timeout, far below the test timeout: failing here
/// means the call would have waited forever.
const _noHang = Duration(seconds: 8);

void main() {
  for (final tls in [false, true]) {
    group(tls ? 'TLS' : 'plain', () {
      test('open() fails when the server closes after the startup message',
          () async {
        final server =
            await _FakeServer.start(tls: tls, onStartup: _OnStartup.close);
        addTearDown(server.close);
        final watch = Stopwatch()..start();
        await expectLater(_open(server.port).timeout(_noHang),
            throwsA(isA<PostgreSQLException>()));
        // Not by the timeout: the end of the socket ended it.
        expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      });

      test('open() times out on a server that never answers, and closes',
          () async {
        final server =
            await _FakeServer.start(tls: tls, onStartup: _OnStartup.ignore);
        addTearDown(server.close);
        await expectLater(
            _open(server.port, connectTimeout: const Duration(seconds: 1))
                .timeout(_noHang),
            throwsA(isA<TimeoutException>()));
        await server.clientClosed.future.timeout(const Duration(seconds: 2));
      });

      test('a query fails when the server closes before replying', () async {
        final server = await _FakeServer.start(
            tls: tls, onStartup: _OnStartup.acceptThenCloseOnQuery);
        addTearDown(server.close);
        final connection = await _open(server.port).timeout(_noHang);
        await expectLater(connection.execute('select 1').timeout(_noHang),
            throwsA(isA<PostgreSQLException>()));
        await connection.close().timeout(_noHang);
      });
    });
  }

  test('a query after the server closed fails at once', () async {
    final server = await _FakeServer.start(
        tls: false, onStartup: _OnStartup.acceptThenCloseOnQuery);
    addTearDown(server.close);
    final connection = await _open(server.port).timeout(_noHang);
    await expectLater(connection.execute('select 1').timeout(_noHang),
        throwsA(isA<PostgreSQLException>()));
    await expectLater(connection.execute('select 2').timeout(_noHang),
        throwsA(isA<PostgreSQLException>()));
    await connection.close().timeout(_noHang);
  });

  test('close() of a connection that is still open ends', () async {
    final server = await _FakeServer.start(
        tls: false, onStartup: _OnStartup.acceptThenCloseOnQuery);
    addTearDown(server.close);
    final connection = await _open(server.port).timeout(_noHang);
    await connection.close().timeout(_noHang);
    await server.clientClosed.future.timeout(const Duration(seconds: 2));
  });
}
