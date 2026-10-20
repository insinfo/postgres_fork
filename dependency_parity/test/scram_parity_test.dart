// Compara lib/src/auth/scram.dart com o pacote `sasl_scram` 0.1.1.
//
// ignore_for_file: implementation_imports

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:postgres_fork/src/auth/scram.dart' as mine;
import 'package:sasl_scram/sasl_scram.dart' as orig;
import 'package:saslprep/saslprep.dart' as orig_saslprep;
import 'package:test/test.dart';

class _FixedGenerator extends orig.RandomStringGenerator {
  final String value;
  _FixedGenerator(this.value);

  @override
  String generate(int length) => value;
}

class _OrigAuthenticator extends orig.SaslAuthenticator {
  _OrigAuthenticator(super.mechanism);
}

/// Par de autenticadores (original e novo) com o mesmo nonce.
class _Pair {
  final orig.SaslAuthenticator original;
  final mine.ScramSha256Authenticator replacement;

  _Pair(String? username, String? password, String nonce)
      : original = _OrigAuthenticator(orig.ScramMechanism(
            'SCRAM-SHA-256',
            crypto.sha256,
            orig.UsernamePasswordCredential(
                username: username, password: password),
            _FixedGenerator(nonce))),
        replacement = mine.ScramSha256Authenticator(
            username: username,
            password: password,
            nonceGenerator: (_) => nonce);

  static const _origTypes = [
    orig.SaslMessageType.AuthenticationSASL,
    orig.SaslMessageType.AuthenticationSASLContinue,
    orig.SaslMessageType.AuthenticationSASLFinal,
  ];

  static const _mineTypes = [
    mine.SaslMessageType.AuthenticationSASL,
    mine.SaslMessageType.AuthenticationSASLContinue,
    mine.SaslMessageType.AuthenticationSASLFinal,
  ];

  /// Envia a mesma mensagem aos dois e verifica que o resultado é idêntico.
  String step(int type, List<int> bytes) {
    final a = _outcome(() =>
        original.handleMessage(_origTypes[type], Uint8List.fromList(bytes)));
    final b = _outcome(() => replacement.handleMessage(
        _mineTypes[type], Uint8List.fromList(bytes)));
    expect(b, a);
    return a;
  }
}

String _outcome(Uint8List? Function() fn) {
  try {
    final result = fn();
    return result == null ? 'null' : 'bytes:${result.toList()}';
  } catch (e) {
    // SaslScramException é outro tipo, mas com o mesmo nome e mensagem.
    return 'error:${e.runtimeType}:$e';
  }
}

List<int> _hmac(List<int> key, List<int> data) =>
    crypto.Hmac(crypto.sha256, key).convert(data).bytes;

/// Senha após o SASLprep original, ou null se ele a rejeitar.
String? _prepared(String password) {
  try {
    return orig_saslprep.Saslprep.saslprep(password);
  } on Exception {
    return null;
  } on RangeError {
    return null;
  }
}

/// Calcula, como um servidor faria, a mensagem final esperada. Senhas
/// rejeitadas pelo SASLprep são usadas como estão (como no PostgreSQL).
String _serverFinal(String password, List<int> salt, int iterations,
    String clientFirstBare, String serverFirst, String clientFinalNoProof) {
  final key = utf8.encode(_prepared(password) ?? password);
  var u = _hmac(key, [...salt, 0, 0, 0, 1]);
  final salted = List<int>.from(u);
  for (var i = 1; i < iterations; i++) {
    u = _hmac(key, u);
    for (var j = 0; j < salted.length; j++) {
      salted[j] ^= u[j];
    }
  }
  final serverKey = _hmac(salted, utf8.encode('Server Key'));
  final authMessage = '$clientFirstBare,$serverFirst,$clientFinalNoProof';
  return 'v=${base64.encode(_hmac(serverKey, utf8.encode(authMessage)))}';
}

final _passwords = <String>[
  'postgres', 'dart', 'senha', '', ' ', 'a,b=c', 'p\u00E4ssw\u00F6rd',
  'p\u00F6stgr\u0113s_\u00FC\u0161\u0119r_p\u00E6ssw\u0153\u00EArd',
  'senha\u00B2', '\uFF50\uFF41\uFF53\uFF53', '\uFB01le', 'I\u00ADX',
  '\u2168', 'pass\u2003word', '\u0007bell', '\uE000', '\u0221',
  '\u0627\u0031', '\u0627\u0031\u0628', '\u00AD', '\u{1D400}x',
  'e\u0301\u0316', '\u1100\u1161\u11A8', '\uD800',
];

void main() {
  test('troca completa com senhas variadas', () {
    final random = Random(30);
    var completed = 0;
    var rejected = 0;
    for (final password in [
      ..._passwords,
      for (var i = 0; i < 40; i++)
        String.fromCharCodes(List.generate(
            random.nextInt(20), (_) => 0x21 + random.nextInt(94))),
    ]) {
      for (final iterations in [1, 2, 4096]) {
        final nonce = orig.CryptoStrengthStringGenerator().generate(24);
        final pair = _Pair('user', password, nonce);

        pair.step(0, utf8.encode('SCRAM-SHA-256'));
        final clientFirst =
            utf8.decode(pair.replacement.currentStep.bytesToSendToServer);
        final clientFirstBare = clientFirst.substring(3);

        final salt = List.generate(16, (_) => random.nextInt(256));
        final serverFirst = 'r=${nonce}srv${random.nextInt(1 << 30)},'
            's=${base64.encode(salt)},i=$iterations';
        if (_prepared(password) == null) {
          // Divergência intencional: o sasl_scram lança a exceção do
          // SASLprep; a implementação nova usa a senha como está (libpq).
          rejected++;
          final original = _outcome(() => pair.original.handleMessage(
              orig.SaslMessageType.AuthenticationSASLContinue,
              Uint8List.fromList(utf8.encode(serverFirst))));
          expect(original, startsWith('error'));
          pair.replacement.handleMessage(
              mine.SaslMessageType.AuthenticationSASLContinue,
              Uint8List.fromList(utf8.encode(serverFirst)));
          final clientFinal =
              utf8.decode(pair.replacement.currentStep.bytesToSendToServer);
          final serverFinal = _serverFinal(password, salt, iterations,
              clientFirstBare, serverFirst,
              clientFinal.substring(0, clientFinal.indexOf(',p=')));
          expect(
              pair.replacement.handleMessage(
                  mine.SaslMessageType.AuthenticationSASLFinal,
                  Uint8List.fromList(utf8.encode(serverFinal))),
              isNull);
          continue;
        }
        pair.step(1, utf8.encode(serverFirst));

        final clientFinal =
            utf8.decode(pair.replacement.currentStep.bytesToSendToServer);
        final clientFinalNoProof =
            clientFinal.substring(0, clientFinal.indexOf(',p='));
        final serverFinal = _serverFinal(password, salt, iterations,
            clientFirstBare, serverFirst, clientFinalNoProof);

        expect(pair.step(2, utf8.encode(serverFinal)), 'null');
        completed++;
        // Depois de concluída, qualquer nova mensagem é um erro.
        expect(pair.step(2, utf8.encode(serverFinal)), startsWith('error'));
        expect(pair.step(1, utf8.encode(serverFinal)), startsWith('error'));
      }
    }
    expect(completed, greaterThan(150));
    expect(rejected, greaterThan(10));
  });

  test('mensagens inválidas do servidor', () {
    const nonce = 'fixedNonce0123456789abcd';
    final badServerFirst = <List<int>>[
      utf8.encode('r=outroNonce,s=c2FsdA==,i=4096'),
      utf8.encode('s=c2FsdA==,i=4096'),
      utf8.encode('r=${nonce}x,s=c2FsdA=='),
      utf8.encode('r=${nonce}x,i=4096'),
      utf8.encode('r=${nonce}x,s=***,i=4096'),
      utf8.encode('r=${nonce}x,s=c2FsdA==,i=abc'),
      utf8.encode('r=${nonce}x,s=c2FsdA==,i=0'),
      utf8.encode('r=${nonce}x,s=c2FsdA==,i=-3'),
      utf8.encode('r=${nonce}x,s=c2FsdA==,i=4096,'),
      utf8.encode('r=${nonce}x,s=c2FsdA==,i=4096,x'),
      utf8.encode('r=${nonce}x,s=c2FsdA==,i=4096,e=other-error'),
      utf8.encode(''),
      [0xFF, 0xFE, 0x00],
    ];
    for (final message in badServerFirst) {
      final pair = _Pair('user', 'pencil', nonce);
      pair.step(0, const []);
      pair.step(1, message);
    }

    final badServerFinal = <List<int>>[
      utf8.encode('v=AAAA'),
      utf8.encode('e=invalid-proof'),
      utf8.encode('v='),
      utf8.encode('v=***'),
      utf8.encode(''),
      [0xC3],
    ];
    for (final message in badServerFinal) {
      final pair = _Pair('user', 'pencil', nonce);
      pair.step(0, const []);
      pair.step(1, utf8.encode('r=${nonce}x,s=c2FsdA==,i=1'));
      pair.step(2, message);
    }
  });

  test('ordem inesperada e credenciais nulas', () {
    const nonce = 'abcdefghijklmnopqrstuvwx';
    // Continue/Final antes do início.
    _Pair('user', 'pencil', nonce).step(1, utf8.encode('r=x'));
    _Pair('user', 'pencil', nonce).step(2, utf8.encode('v=x'));
    // Usuário nulo.
    _Pair(null, 'pencil', nonce).step(0, const []);
    // Senha nula (falha no Continue).
    final pair = _Pair('user', null, nonce);
    pair.step(0, const []);
    pair.step(1, utf8.encode('r=${nonce}x,s=c2FsdA==,i=1'));
    // Reinício da conversa.
    final restart = _Pair('user', 'pencil', nonce);
    restart.step(0, const []);
    restart.step(0, const []);
    restart.step(1, utf8.encode('r=${nonce}x,s=c2FsdA==,i=1'));
  });

  test('gerador de nonce: mesmo alfabeto e tamanho', () {
    expect(mine.scramNonceCharacters,
        orig.RandomStringGenerator.allowedCharacters);
    expect(mine.scramDefaultNonceLength,
        orig.SaslAuthenticator.DefaultNonceLength);
    for (var i = 0; i < 200; i++) {
      final nonce = mine.generateScramNonce(24);
      expect(nonce.length, 24);
      expect(
          nonce.split('').every(mine.scramNonceCharacters.contains), isTrue);
    }
  });
}
