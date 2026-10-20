import 'dart:convert';

import '../client_messages.dart';
import '../encoded_string.dart';
import '../server_messages.dart';
import '../utils/buffer.dart';
import '../utils/crypto.dart';
import 'auth.dart';

class MD5Authenticator extends PostgresAuthenticator {
  static final String name = 'MD5';

  MD5Authenticator(PostgresAuthConnection connection, Encoding encoding)
      : super(connection, encoding);

  @override
  void onMessage(AuthenticationMessage message) {
    final reader = ByteDataReader()..add(message.bytes);
    final salt = reader.read(4, copy: true);

    final authMessage = AuthMD5Message(
        connection.username!, connection.password!, salt, encoding);

    connection.sendMessage(authMessage);
  }
}

class AuthMD5Message extends ClientMessage {
  EncodedString? _hashedAuthString;

  AuthMD5Message(String username, String password, List<int> saltBytes,
      // ignore: avoid_unused_constructor_parameters
      Encoding encoding) {
    // Como o libpq (pg_md5_encrypt): md5(senha + usuário) sobre os bytes
    // UTF-8 e depois md5(hash em hexadecimal + salt). O PostgreSQL guarda o
    // hash calculado sobre os bytes da senha na codificação do servidor
    // (normalmente UTF-8).
    final passwordHash = md5Hex(utf8.encode('$password$username'));
    final md5Hash = md5Hex([...ascii.encode(passwordHash), ...saltBytes]);
    _hashedAuthString = EncodedString('md5$md5Hash', utf8);
  }

  @override
  void applyToBuffer(ByteDataWriter buffer) {
    buffer.writeUint8(ClientMessage.PasswordIdentifier);
    final length = 5 + _hashedAuthString!.byteLength;
    buffer.writeUint32(length);
    _hashedAuthString!.applyToBuffer(buffer);
  }
}
