// PostgreSQLConnection.securityContext: a private CA verifies the server and
// the client certificate reaches it.
//
// A fake server on loopback answers 'S' to the SSLRequest and accepts TLS with
// the certificates in test/fixtures/tls (made for these tests only, see
// generate.sh). The startup message reaching it means the client accepted the
// server: it carries the user name.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:postgres_fork/postgres.dart';
import 'package:postgres_fork/postgres_v3_experimental.dart' as v3;
import 'package:test/test.dart';

const _dir = 'test/fixtures/tls';

bool _isSslRequest(List<int> chunk) {
  if (chunk.length < 8) return false;
  final data = ByteData.sublistView(Uint8List.fromList(chunk));
  return data.getInt32(0) == 8 && data.getInt32(4) == 80877103;
}

class _FakeServer {
  _FakeServer._(this._socket, this._context, this._requireClient) {
    _socket.listen(_serve);
  }

  static Future<_FakeServer> start(
      {String certificate = 'server', bool requireClient = false}) async {
    final context = SecurityContext()
      ..useCertificateChain('$_dir/$certificate.pem')
      ..usePrivateKey('$_dir/$certificate-key.pem');
    if (requireClient) {
      context
        ..setTrustedCertificates('$_dir/ca.pem')
        ..setClientAuthorities('$_dir/ca.pem');
    }
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    return _FakeServer._(server, context, requireClient);
  }

  final ServerSocket _socket;
  final SecurityContext _context;
  final bool _requireClient;

  bool startupReceived = false;
  String? clientSubject;

  int get port => _socket.port;

  void _serve(Socket client) {
    // ignore: cancel_subscriptions
    late StreamSubscription<Uint8List> sub;
    sub = client.listen((chunk) async {
      if (!_isSslRequest(chunk)) return;
      sub.pause();
      client.add([83]); // 'S'
      await client.flush();
      try {
        final secure = await SecureSocket.secureServer(client, _context,
            requireClientCertificate: _requireClient);
        clientSubject = secure.peerCertificate?.subject;
        await secure.first;
        startupReceived = true;
        secure.destroy();
      } catch (_) {
        // The handshake failed: the client rejected the certificate, or the
        // server rejected the client.
      }
    }, onError: (_) {});
  }

  Future<void> close() => _socket.close();
}

SecurityContext _trusting(String ca) =>
    SecurityContext()..setTrustedCertificates('$_dir/$ca.pem');

SecurityContext _withClientCertificate(SecurityContext context) => context
  ..useCertificateChain('$_dir/client.pem')
  ..usePrivateKey('$_dir/client-key.pem');

Future<Object?> _open(int port, PgSslMode mode,
    {SecurityContext? securityContext}) async {
  final connection = PostgreSQLConnection('localhost', port, 'db',
      username: 'u',
      password: 'p',
      timeoutInSeconds: 5,
      sslMode: mode,
      securityContext: securityContext);
  try {
    await connection.open();
    return null;
  } catch (e) {
    return e;
  } finally {
    try {
      await connection.close();
    } catch (_) {}
  }
}

/// Lets the fake server see what the client sent before the assertions.
Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  group('verifyFull', () {
    test('a context with the CA verifies the server', () async {
      final server = await _FakeServer.start();
      addTearDown(server.close);
      await _open(server.port, PgSslMode.verifyFull,
          securityContext: _trusting('ca'));
      await _settle();
      expect(server.startupReceived, isTrue);
    });

    test('without a context the system roots reject the private CA', () async {
      final server = await _FakeServer.start();
      addTearDown(server.close);
      final error = await _open(server.port, PgSslMode.verifyFull);
      await _settle();
      expect('$error', contains('CERTIFICATE_VERIFY_FAILED'));
      expect(server.startupReceived, isFalse);
    });

    test('a context with another CA rejects the certificate', () async {
      final server = await _FakeServer.start();
      addTearDown(server.close);
      final error = await _open(server.port, PgSslMode.verifyFull,
          securityContext: _trusting('other-ca'));
      await _settle();
      expect('$error', contains('CERTIFICATE_VERIFY_FAILED'));
      expect(server.startupReceived, isFalse);
    });

    test('a certificate for another host is rejected', () async {
      final server = await _FakeServer.start(certificate: 'server-other-host');
      addTearDown(server.close);
      final error = await _open(server.port, PgSslMode.verifyFull,
          securityContext: _trusting('ca'));
      await _settle();
      expect(error, isNotNull);
      expect(server.startupReceived, isFalse);
    });
  });

  group('client certificate', () {
    for (final mode in [PgSslMode.verifyFull, PgSslMode.require]) {
      test('reaches the server with $mode', () async {
        final server = await _FakeServer.start(requireClient: true);
        addTearDown(server.close);
        await _open(server.port, mode,
            securityContext: _withClientCertificate(_trusting('ca')));
        await _settle();
        expect(server.startupReceived, isTrue);
        expect(server.clientSubject, contains('eloquent-client'));
      });
    }

    test('a server that requires one refuses a client without it', () async {
      final server = await _FakeServer.start(requireClient: true);
      addTearDown(server.close);
      await _open(server.port, PgSslMode.verifyFull,
          securityContext: _trusting('ca'));
      await _settle();
      expect(server.startupReceived, isFalse);
    });
  });

  group('PgSessionSettings.securityContext', () {
    Future<Object?> openV3(int port, SecurityContext? context) async {
      try {
        final connection = await v3.PgConnection.open(
            v3.PgEndpoint(
                host: 'localhost',
                port: port,
                database: 'db',
                username: 'u',
                password: 'p',
                requireSsl: true),
            sessionSettings: v3.PgSessionSettings(
                connectTimeout: const Duration(seconds: 5),
                securityContext: context))
            // The fake server closes after the startup message, and open()
            // does not end when that happens.
            .timeout(const Duration(seconds: 2));
        await connection.close();
        return null;
      } catch (e) {
        return e;
      }
    }

    test('a context with the CA verifies the server', () async {
      final server = await _FakeServer.start();
      addTearDown(server.close);
      await openV3(server.port, _trusting('ca'));
      await _settle();
      expect(server.startupReceived, isTrue);
    });

    test('without a context the private CA is rejected', () async {
      final server = await _FakeServer.start();
      addTearDown(server.close);
      await openV3(server.port, null);
      await _settle();
      expect(server.startupReceived, isFalse);
    });
  });

  group('a securityContext without SSL throws', () {
    test('sslMode disable', () {
      expect(
          () => PostgreSQLConnection('localhost', 5432, 'db',
              sslMode: PgSslMode.disable, securityContext: SecurityContext()),
          throwsArgumentError);
    });

    test('no sslMode and no useSSL', () {
      expect(
          () => PostgreSQLConnection('localhost', 5432, 'db',
              securityContext: SecurityContext()),
          throwsArgumentError);
    });

    test('useSSL enables it', () {
      expect(
          PostgreSQLConnection('localhost', 5432, 'db',
                  useSSL: true, securityContext: SecurityContext())
              .effectiveSslMode,
          PgSslMode.require);
    });
  });
}
