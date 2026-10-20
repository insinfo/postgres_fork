import 'dart:convert';
import 'dart:typed_data';

import 'package:postgres_fork/src/auth/scram.dart';
import 'package:test/test.dart';

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

String? _send(ScramSha256Authenticator auth, SaslMessageType type,
    [String message = '']) {
  final result = auth.handleMessage(type, _bytes(message));
  return result == null ? null : utf8.decode(result);
}

Matcher _throwsScram(String message) => throwsA(isA<SaslScramException>()
    .having((e) => e.toString(), 'toString', 'SaslScramDart Exception: $message'));

void main() {
  // Valores esperados calculados de forma independente (Python: hashlib,
  // hmac e unicodedata) a partir do exemplo do RFC 7677.
  const nonce = 'rOprNGfwEbeRWgbNEkqO';
  const serverFirst = 'r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF\$k0,'
      's=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096';

  ScramSha256Authenticator newAuth(
          {String? username = 'user', String? password = 'pencil'}) =>
      ScramSha256Authenticator(
          username: username,
          password: password,
          nonceGenerator: (_) => nonce);

  test('troca completa', () {
    final auth = newAuth();
    expect(auth.mechanismName, 'SCRAM-SHA-256');
    expect(_send(auth, SaslMessageType.AuthenticationSASL), 'n,,n=*,r=$nonce');
    expect(
        _send(auth, SaslMessageType.AuthenticationSASLContinue, serverFirst),
        'c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF\$k0,'
        'p=3M3hagGCCg+02mpnZ9fgyMWejs8yYlqFo7tFZyBIV5g=');
    expect(
        _send(auth, SaslMessageType.AuthenticationSASLFinal,
            'v=jBUU2ZmyQ4x+QJe05Kx6JFwPHDsiK3tfmR51qZfjEOY='),
        isNull);
    expect(() => _send(auth, SaslMessageType.AuthenticationSASLFinal, 'v=x'),
        _throwsScram('Sasl conversation has completed'));
  });

  test('senha normalizada pelo SASLprep', () {
    final auth = ScramSha256Authenticator(
        username: 'user',
        password: 'ﬁle-senha²',
        nonceGenerator: (_) => 'abcdefghijklmnopqrstuvwx');
    _send(auth, SaslMessageType.AuthenticationSASL);
    expect(
        _send(auth, SaslMessageType.AuthenticationSASLContinue,
            'r=abcdefghijklmnopqrstuvwxSERVER,s=c2FsdHNhbHQ=,i=1'),
        'c=biws,r=abcdefghijklmnopqrstuvwxSERVER,'
        'p=zoS4z7BWCquRJNAsL5rce2Exx/9oBAkylFOuOY72A6o=');
    expect(
        _send(auth, SaslMessageType.AuthenticationSASLFinal,
            'v=1+ZtRDaLF2eCyI9PMT4F8XUQlkaXfblI204PWrKjyos='),
        isNull);
  });

  test('senha rejeitada pelo SASLprep é usada como está (como o libpq)', () {
    final auth = ScramSha256Authenticator(
        username: 'user',
        password: 'abc${String.fromCharCode(7)}def',
        nonceGenerator: (_) => 'abcdefghijklmnopqrstuvwx');
    _send(auth, SaslMessageType.AuthenticationSASL);
    expect(
        _send(auth, SaslMessageType.AuthenticationSASLContinue,
            'r=abcdefghijklmnopqrstuvwxSERVER,s=c2FsdHNhbHQ=,i=1'),
        'c=biws,r=abcdefghijklmnopqrstuvwxSERVER,'
        'p=pW42sS4AUJiUzh3CiT3ghPKIs7bGrOUjOxNcERsyD90=');
    expect(
        _send(auth, SaslMessageType.AuthenticationSASLFinal,
            'v=oJL8wWPGm9JNbne/KSQNDmjTvgPDcU8uIVU19ypOOgE='),
        isNull);
  });

  test('assinatura do servidor inválida', () {
    final auth = newAuth();
    _send(auth, SaslMessageType.AuthenticationSASL);
    _send(auth, SaslMessageType.AuthenticationSASLContinue, serverFirst);
    expect(() => _send(auth, SaslMessageType.AuthenticationSASLFinal, 'v=AAAA'),
        _throwsScram('Server signature was invalid.'));
  });

  test('nonce do servidor inválido', () {
    final auth = newAuth();
    _send(auth, SaslMessageType.AuthenticationSASL);
    expect(
        () => _send(auth, SaslMessageType.AuthenticationSASLContinue,
            'r=outro,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096'),
        _throwsScram('Server sent an invalid nonce.'));
  });

  test('usuário vazio', () {
    expect(() => _send(newAuth(username: null), SaslMessageType.AuthenticationSASL),
        _throwsScram('Username is empty on initialization'));
  });

  test('nonce gerado', () {
    final nonce = generateScramNonce(scramDefaultNonceLength);
    expect(nonce, hasLength(24));
    expect(nonce, isNot(contains(',')));
    expect(nonce.split('').every(scramNonceCharacters.contains), isTrue);
    expect(generateScramNonce(24), isNot(nonce));
  });
}
