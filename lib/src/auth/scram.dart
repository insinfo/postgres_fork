// Cliente SCRAM-SHA-256 (RFC 5802 / RFC 7677) usado na autenticação SASL do
// PostgreSQL.
//
// Substitui o pacote `sasl_scram` 0.1.1 (MIT, Copyright (c) 2021 mongo-dart)
// mantendo o mesmo comportamento: mesma máquina de estados, mesmo formato de
// mensagens, mesmo gerador de nonce e mesmas exceções/mensagens de erro.
// Única diferença: senhas rejeitadas pelo SASLprep são usadas como estão
// (como faz o libpq), em vez de lançar uma exceção.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../utils/crypto.dart';
import '../utils/saslprep.dart';

// ignore_for_file: constant_identifier_names

/// Tipo da mensagem SASL recebida do servidor.
enum SaslMessageType {
  AuthenticationSASL,
  AuthenticationSASLContinue,
  AuthenticationSASLFinal,
}

/// Erro na troca de mensagens SCRAM.
class SaslScramException implements Exception {
  final String message;

  SaslScramException(this.message);

  @override
  String toString() => 'SaslScramDart Exception: $message';
}

/// Caracteres usados para gerar o nonce do cliente (não inclui `,`).
const scramNonceCharacters = '!"#\'\$%&()*+-./0123456789:;<=>?@'
    'ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~';

/// Tamanho do nonce gerado pelo cliente.
const scramDefaultNonceLength = 24;

/// Gera uma string aleatória criptograficamente segura com [length]
/// caracteres de [scramNonceCharacters].
String generateScramNonce(int length) {
  final random = Random.secure();
  final allowedCodeUnits = scramNonceCharacters.codeUnits;
  final max = allowedCodeUnits.length;
  final randomString = <int>[];
  for (var i = 0; i < length; ++i) {
    randomString.add(allowedCodeUnits.elementAt(random.nextInt(max)));
  }
  return String.fromCharCodes(randomString);
}

const _gs2Header = 'n,,';

/// Autenticador SCRAM-SHA-256 do lado do cliente.
class ScramSha256Authenticator {
  /// Nome do mecanismo enviado ao servidor.
  final String mechanismName = 'SCRAM-SHA-256';

  final String? username;
  final String? password;
  final String Function(int length) _nonceGenerator;

  // O nome é o mesmo do pacote original para que o erro de inicialização
  // tardia (mensagem fora de ordem) seja idêntico.
  // ignore: library_private_types_in_public_api
  late _ScramStep currentStep;

  ScramSha256Authenticator({
    required this.username,
    required this.password,
    String Function(int length)? nonceGenerator,
  }) : _nonceGenerator = nonceGenerator ?? generateScramNonce;

  /// Processa uma mensagem SASL do servidor e retorna os bytes a enviar como
  /// resposta, ou `null` quando não há resposta (mensagem final).
  Uint8List? handleMessage(
      SaslMessageType msgType, Uint8List bytesReceivedFromServer) {
    switch (msgType) {
      case SaslMessageType.AuthenticationSASL:
        currentStep = _initialize();
        break;
      case SaslMessageType.AuthenticationSASLContinue:
        currentStep = currentStep.transition(bytesReceivedFromServer);
        break;
      case SaslMessageType.AuthenticationSASLFinal:
        currentStep = currentStep.transition(bytesReceivedFromServer);
        return null;
    }
    return currentStep.bytesToSendToServer;
  }

  _ScramStep _initialize() {
    if (username == null) {
      throw SaslScramException('Username is empty on initialization');
    }

    // O PostgreSQL ignora o usuário do SCRAM (usa o da mensagem de startup).
    const usernamePart = 'n=*';
    final r = _nonceGenerator(scramDefaultNonceLength);
    final nonce = 'r=$r';

    final clientFirstMessageBare = '$usernamePart,$nonce';
    final clientFirstMessage = '$_gs2Header$clientFirstMessageBare';

    return _ClientFirst(_coerceUint8List(utf8.encode(clientFirstMessage)),
        password, clientFirstMessageBare, r);
  }
}

abstract class _ScramStep {
  final Uint8List bytesToSendToServer;

  _ScramStep(this.bytesToSendToServer);

  _ScramStep transition(List<int> bytesReceivedFromServer);
}

class _ClientFirst extends _ScramStep {
  final String clientFirstMessageBare;
  final String? password;
  final String rPrefix;

  _ClientFirst(Uint8List bytesToSendToServer, this.password,
      this.clientFirstMessageBare, this.rPrefix)
      : super(bytesToSendToServer);

  @override
  _ScramStep transition(List<int> bytesReceivedFromServer) {
    final serverFirstMessage = utf8.decode(bytesReceivedFromServer);

    final decodedMessage = _parsePayload(serverFirstMessage);

    final r = decodedMessage['r'];
    if (r == null || !r.startsWith(rPrefix)) {
      throw SaslScramException('Server sent an invalid nonce.');
    }

    final s = decodedMessage['s'];
    final i = int.parse(decodedMessage['i'].toString());

    final encodedHeader = base64.encode(utf8.encode(_gs2Header));
    final channelBinding = 'c=$encodedHeader';
    final nonce = 'r=$r';
    final clientFinalMessageWithoutProof = '$channelBinding,$nonce';

    // Como o libpq (fe-auth-scram.c): se o SASLprep rejeitar a senha
    // (caracteres proibidos, não atribuídos, regras bidirecionais ou
    // resultado vazio), usa a senha original.
    final rawPassword = password!;
    String passwordDigest;
    try {
      passwordDigest = saslprep(rawPassword);
    } on Exception {
      passwordDigest = rawPassword;
    } on RangeError {
      passwordDigest = rawPassword;
    }

    final salt = base64.decode(s.toString());

    final saltedPassword = _hi(passwordDigest, salt, i);
    final clientKey = _computeHmac(saltedPassword, 'Client Key');
    final storedKey = sha256Bytes(clientKey);
    final authMessage =
        '$clientFirstMessageBare,$serverFirstMessage,$clientFinalMessageWithoutProof';
    final clientSignature = _computeHmac(storedKey, authMessage);
    final clientProof = _xor(clientKey, clientSignature);
    final serverKey = _computeHmac(saltedPassword, 'Server Key');
    final serverSignature = _computeHmac(serverKey, authMessage);

    final base64clientProof = base64.encode(clientProof);
    final proof = 'p=$base64clientProof';
    final clientFinalMessage = '$clientFinalMessageWithoutProof,$proof';

    return _ClientLast(
        _coerceUint8List(utf8.encode(clientFinalMessage)), serverSignature);
  }
}

class _ClientLast extends _ScramStep {
  final Uint8List serverSignature64;

  _ClientLast(Uint8List bytesToSendToServer, this.serverSignature64)
      : super(bytesToSendToServer);

  @override
  _ScramStep transition(List<int> bytesReceivedFromServer) {
    final decodedMessage = _parsePayload(utf8.decode(bytesReceivedFromServer));
    final serverSignature = base64.decode(decodedMessage['v'].toString());

    if (!_bytesEqual(serverSignature64, serverSignature)) {
      throw SaslScramException('Server signature was invalid.');
    }

    return _ClientCompleted();
  }
}

class _ClientCompleted extends _ScramStep {
  _ClientCompleted() : super(Uint8List(0));

  @override
  _ScramStep transition(List<int> bytesReceivedFromServer) {
    throw SaslScramException('Sasl conversation has completed');
  }
}

Map<String, String> _parsePayload(String payload) {
  final dict = <String, String>{};
  final parts = payload.split(',');

  for (var i = 0; i < parts.length; i++) {
    final key = parts[i][0];
    final value = parts[i].substring(2);
    dict[key] = value;
  }

  return dict;
}

Uint8List _coerceUint8List(List<int> list) =>
    list is Uint8List ? list : Uint8List.fromList(list);

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// HMAC-SHA256 com a chave [key] sobre a string [message] em UTF-8.
Uint8List _computeHmac(Uint8List key, String message) =>
    hmacSha256(key, utf8.encode(message));

Uint8List _xor(Uint8List a, Uint8List b) {
  final length = a.length > b.length ? b.length : a.length;
  final result = Uint8List(length);
  for (var i = 0; i < length; i++) {
    result[i] = a[i] ^ b[i];
  }
  return result;
}

/// Função Hi() do RFC 5802 (PBKDF2 com HMAC-SHA256 e um único bloco).
Uint8List _hi(String password, Uint8List salt, int iterations) {
  final key = utf8.encode(password);
  Uint8List digest(List<int> msg) => hmacSha256(key, msg);

  final newSalt = Uint8List.fromList(List.from(salt)..addAll([0, 0, 0, 1]));

  var ui = digest(newSalt);
  var u1 = ui;

  for (var i = 0; i < iterations - 1; i++) {
    u1 = digest(u1);
    ui = _xor(ui, u1);
  }

  return ui;
}
